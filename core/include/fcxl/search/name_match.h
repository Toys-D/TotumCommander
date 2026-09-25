#pragma once
/// @file name_match.h
/// Matching a file name against a mask the way the user reads it rather than the way the bytes
/// happen to fall.
///
/// Two things make a byte comparison the wrong tool on this platform:
///
/// - **Unicode form.** macOS stores a name in whatever form it was written with and hands it
///   back unchanged. Everything written through Cocoa — Finder, this app, an unpacked archive —
///   writes the DECOMPOSED form, where "ё" is "е" followed by the combining diaeresis U+0308,
///   while a mask typed on the keyboard arrives COMPOSED. One name on screen, two byte strings
///   underneath.
/// - **Case.** `fnmatch`'s `FNM_CASEFOLD` folds ASCII and nothing else, so "*.TXT" found
///   "file.txt" while "ОТЧЁТ*" found no "отчёт.pdf".
///
/// Both sides are therefore brought to one form — composed and case-folded — and compared as
/// CHARACTERS, which is also what makes `?` stand for one character instead of one byte.
#include <string>
#include <string_view>

namespace fcxl::search {

/// The composed (NFC) form of @p text, for comparisons that do their own matching — the regex
/// search, which keeps its own case rules and only needs the two forms folded together.
/// Text that is not valid UTF-8 is returned unchanged.
[[nodiscard]] auto to_composed_form(std::string_view text) -> std::string;

/// A file-name mask: `*` for any run of characters, `?` for one, `[abc]` / `[a-z]` / `[!abc]`
/// for a set of them, and `\` to take the next character literally — the syntax `fnmatch` gave
/// this search before it learned to read Unicode.
///
/// Prepared once and matched against many names, because folding the mask costs the same as
/// folding a name and a search walks thousands of them.
class NameMask {
public:
    explicit NameMask(std::string_view mask);

    /// Whether @p name matches, ignoring case and the Unicode form of both sides.
    [[nodiscard]] auto matches(std::string_view name) const -> bool;

private:
    std::u32string folded_mask_;
};

}  // namespace fcxl::search
