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
#include <vector>

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

/// What the "file mask" field holds: one mask or several, separated by semicolons —
/// "*.jpg;*.png", as commander users have always typed it. A name matches when any piece does.
///
/// A piece with no wildcard in it is a piece of a name, not a whole one: "отчёт" means
/// "*отчёт*". An empty set, or one holding a bare "*", lets every name through.
class NameMaskSet {
public:
    explicit NameMaskSet(std::string_view spec);

    [[nodiscard]] auto matches(std::string_view name) const -> bool;
    /// True when no name can fail — a caller may then skip the question altogether.
    [[nodiscard]] auto matches_everything() const -> bool { return everything_; }

private:
    std::vector<NameMask> masks_;
    bool everything_ = false;
};

/// Text brought to one case for a case-blind comparison, still UTF-8. Bytes that are not
/// UTF-8 get the ASCII part of the job and are otherwise returned as they came.
[[nodiscard]] auto to_folded_text(std::string_view text) -> std::string;

}  // namespace fcxl::search
