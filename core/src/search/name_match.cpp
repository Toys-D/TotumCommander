#include "fcxl/search/name_match.h"

#include <CoreFoundation/CoreFoundation.h>

#include <algorithm>
#include <cstddef>
#include <optional>
#include <string>
#include <string_view>

namespace fcxl::search {
namespace {

/// A CFString over UTF-8 bytes, or `nullptr` when the bytes are not valid UTF-8 — which a file
/// name is free to be. APFS rejects such names, but a FAT, exFAT or NTFS volume and a share on
/// the network all hand them out, as does an archive packed in a legacy encoding.
auto make_mutable_string(std::string_view text) -> CFMutableStringRef {
    CFStringRef immutable = CFStringCreateWithBytes(kCFAllocatorDefault,
                                                    reinterpret_cast<const UInt8*>(text.data()),
                                                    static_cast<CFIndex>(text.size()),
                                                    kCFStringEncodingUTF8,
                                                    false);
    if (immutable == nullptr) {
        return nullptr;
    }
    CFMutableStringRef copy = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, immutable);
    CFRelease(immutable);
    return copy;
}

auto copy_utf8(CFStringRef text) -> std::string {
    const CFIndex length = CFStringGetLength(text);
    if (length == 0) {
        return {};
    }
    CFIndex byte_count = 0;
    const CFRange range = CFRangeMake(0, length);
    CFStringGetBytes(text, range, kCFStringEncodingUTF8, 0, false, nullptr, 0, &byte_count);
    std::string utf8(static_cast<std::size_t>(byte_count), '\0');
    CFStringGetBytes(text, range, kCFStringEncodingUTF8, 0, false,
                     reinterpret_cast<UInt8*>(utf8.data()), byte_count, &byte_count);
    return utf8;
}

void copy_code_points(CFStringRef text, std::u32string& points) {
    points.clear();
    const CFIndex length = CFStringGetLength(text);
    if (length == 0) {
        return;
    }
    CFIndex byte_count = 0;
    const CFRange range = CFRangeMake(0, length);
    CFStringGetBytes(text, range, kCFStringEncodingUTF32LE, 0, false, nullptr, 0, &byte_count);
    points.resize(static_cast<std::size_t>(byte_count) / sizeof(char32_t));
    CFStringGetBytes(text, range, kCFStringEncodingUTF32LE, 0, false,
                     reinterpret_cast<UInt8*>(points.data()), byte_count, &byte_count);
}

auto is_ascii(std::string_view text) -> bool {
    return std::all_of(text.begin(), text.end(),
                       [](const char byte) { return static_cast<unsigned char>(byte) < 0x80; });
}

/// One byte, one character, upper case brought down — the whole of what folding means below
/// U+0080, and the honest best that can be done above it when the bytes are not UTF-8 at all.
void fold_bytes(std::string_view text, std::u32string& folded) {
    folded.clear();
    folded.reserve(text.size());
    for (const char raw : text) {
        const auto byte = static_cast<unsigned char>(raw);
        const bool upper_ascii = byte >= 'A' && byte <= 'Z';
        folded.push_back(static_cast<char32_t>(upper_ascii ? byte + ('a' - 'A') : byte));
    }
}

/// The form both sides of a comparison are brought to: case-folded, then composed. Folding
/// first because it can take a character apart ("ß" becomes "ss"), and the composing pass has
/// to run over what folding left behind.
/// Fills @p folded rather than returning it, so a search walking a whole tree can keep one
/// buffer instead of building a new one per name.
void to_match_form(std::string_view text, std::u32string& folded) {
    // Most names are plain ASCII, which has no second Unicode form and folds by arithmetic. The
    // search runs this over every name in the tree, so that case is worth not paying for.
    if (is_ascii(text)) {
        fold_bytes(text, folded);
        return;
    }
    CFMutableStringRef prepared = make_mutable_string(text);
    if (prepared == nullptr) {
        // Not UTF-8, so there are no characters here to fold or compose — the byte-for-byte
        // comparison this search did before is what is left, and it still lets an ASCII mask
        // ("report_*", rather than "отчёт*") reach such a name.
        fold_bytes(text, folded);
        return;
    }
    CFStringFold(prepared, kCFCompareCaseInsensitive, nullptr);
    CFStringNormalize(prepared, kCFStringNormalizationFormC);
    copy_code_points(prepared, folded);
    CFRelease(prepared);
}

/// One bracket expression — `[abc]`, `[a-z]`, `[!abc]` or `[^abc]` — starting at @p position,
/// which points at the `[`. Tells whether @p character is in the set and moves @p position past
/// the closing `]`. A `]` straight after the opening bracket is a member of the set rather than
/// its end, the way POSIX reads it.
///
/// An unterminated `[` is no set at all: nothing is returned and the caller treats the bracket
/// as an ordinary character, which is what `fnmatch` did with it.
auto match_bracket(const std::u32string& mask, std::size_t& position, char32_t character)
    -> std::optional<bool> {
    std::size_t index = position + 1;
    bool negated = false;
    if (index < mask.size() && (mask[index] == U'!' || mask[index] == U'^')) {
        negated = true;
        ++index;
    }

    bool found = false;
    for (bool first = true; index < mask.size(); ++index, first = false) {
        if (mask[index] == U']' && !first) {
            position = index + 1;
            return found != negated;
        }
        const bool is_range = index + 2 < mask.size() && mask[index + 1] == U'-' &&
                              mask[index + 2] != U']';
        if (is_range) {
            found = found || (character >= mask[index] && character <= mask[index + 2]);
            index += 2;
        } else {
            found = found || character == mask[index];
        }
    }
    return std::nullopt;
}

/// Wildcard matching over characters. `*` is resolved by remembering where it stood and
/// retrying one character further along whenever the rest of the mask runs aground, so the
/// walk stays linear in the usual case instead of branching.
auto matches_folded(const std::u32string& mask, const std::u32string& name) -> bool {
    std::size_t mask_index = 0;
    std::size_t name_index = 0;
    std::size_t star_index = std::u32string::npos;
    std::size_t star_name_index = 0;

    while (name_index < name.size()) {
        if (mask_index < mask.size() && mask[mask_index] == U'*') {
            star_index = mask_index++;
            star_name_index = name_index;
            continue;
        }

        bool consumed = false;
        std::size_t next_mask_index = mask_index;
        if (mask_index < mask.size()) {
            const char32_t token = mask[mask_index];
            if (token == U'?') {
                consumed = true;
                next_mask_index = mask_index + 1;
            } else if (token == U'[') {
                std::size_t after_bracket = mask_index;
                if (const auto in_set = match_bracket(mask, after_bracket, name[name_index])) {
                    consumed = *in_set;
                    next_mask_index = after_bracket;
                } else {
                    consumed = name[name_index] == U'[';
                    next_mask_index = mask_index + 1;
                }
            } else if (token == U'\\' && mask_index + 1 < mask.size()) {
                consumed = name[name_index] == mask[mask_index + 1];
                next_mask_index = mask_index + 2;
            } else {
                consumed = name[name_index] == token;
                next_mask_index = mask_index + 1;
            }
        }

        if (consumed) {
            mask_index = next_mask_index;
            ++name_index;
            continue;
        }
        if (star_index == std::u32string::npos) {
            return false;
        }
        // The last `*` gives up one more character of the name and the rest is tried again.
        mask_index = star_index + 1;
        name_index = ++star_name_index;
    }

    while (mask_index < mask.size() && mask[mask_index] == U'*') {
        ++mask_index;
    }
    return mask_index == mask.size();
}

}  // namespace

auto to_composed_form(std::string_view text) -> std::string {
    if (is_ascii(text)) {
        return std::string(text);
    }
    CFMutableStringRef prepared = make_mutable_string(text);
    if (prepared == nullptr) {
        return std::string(text);
    }
    CFStringNormalize(prepared, kCFStringNormalizationFormC);
    std::string composed = copy_utf8(prepared);
    CFRelease(prepared);
    return composed;
}

NameMask::NameMask(std::string_view mask) {
    to_match_form(mask, folded_mask_);
}

auto NameMask::matches(std::string_view name) const -> bool {
    // Refilled instead of rebuilt, and one per thread so that a mask stays safe to share.
    thread_local std::u32string folded_name;
    to_match_form(name, folded_name);
    return matches_folded(folded_mask_, folded_name);
}

}  // namespace fcxl::search
