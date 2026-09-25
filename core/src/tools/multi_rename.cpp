#include "fcxl/tools/multi_rename.h"

#include <algorithm>
#include <cctype>
#include <filesystem>
#include <iomanip>
#include <regex>
#include <sstream>
#include <string>
#include <unordered_set>

namespace fcxl::tools {
namespace {

/// Apply counter substitution: replace {N}, {N:03}, etc.
auto apply_counter(const std::string& text, std::size_t index) -> std::string {
    std::string result = text;

    // Match patterns like {N}, {N:03}, {N:4}
    std::regex counter_re(R"(\{N(?::(\d+))?\})");
    std::smatch match;
    std::string working = result;
    std::string output;

    while (std::regex_search(working, match, counter_re)) {
        output += match.prefix().str();

        int width = 1;
        if (match[1].matched && !match[1].str().empty()) {
            width = std::stoi(match[1].str());
            if (width < 1) width = 1;
            if (width > 10) width = 10;
        }

        std::ostringstream oss;
        oss << std::setfill('0') << std::setw(width) << (index + 1);
        output += oss.str();

        working = match.suffix().str();
    }
    output += working;

    return output;
}

/// Change case of entire string
auto change_case_str(const std::string& text, bool to_upper) -> std::string {
    std::string result = text;
    if (to_upper) {
        std::transform(result.begin(), result.end(), result.begin(),
                       [](unsigned char c) { return std::toupper(c); });
    } else {
        std::transform(result.begin(), result.end(), result.begin(),
                       [](unsigned char c) { return std::tolower(c); });
    }
    return result;
}

/// Apply a single rename rule to a filename (without path)
auto apply_rule(const std::string& filename, const RenameRule& rule, std::size_t index) -> std::string {
    // Separate stem and extension
    std::filesystem::path p(filename);
    std::string stem = p.stem().string();
    std::string ext = p.extension().string();  // includes dot

    std::string new_stem = stem;

    // Step 1: Search & Replace (plain text or regex)
    if (!rule.search_pattern.empty()) {
        if (rule.use_regex) {
            try {
                std::regex re(rule.search_pattern);
                new_stem = std::regex_replace(new_stem, re, rule.replace_pattern);
            } catch (const std::regex_error&) {
                // Invalid regex — leave unchanged
            }
        } else {
            // Simple text replacement (all occurrences)
            std::string::size_type pos = 0;
            while ((pos = new_stem.find(rule.search_pattern, pos)) != std::string::npos) {
                new_stem.replace(pos, rule.search_pattern.size(), rule.replace_pattern);
                pos += rule.replace_pattern.size();
            }
        }
    }

    // Step 2: Counter substitution in the result
    if (!rule.counter_format.empty()) {
        // If replace_pattern is empty but counter_format is set,
        // append counter to stem
        new_stem = apply_counter(new_stem + rule.counter_format, index);
    } else {
        // Check if replace_pattern itself contains counter tokens
        new_stem = apply_counter(new_stem, index);
    }

    // Step 3: Case change
    if (rule.change_case) {
        // Convention: if replace_pattern is all uppercase, make uppercase; else lowercase
        bool has_upper = !rule.replace_pattern.empty() &&
                         std::all_of(rule.replace_pattern.begin(), rule.replace_pattern.end(),
                                     [](unsigned char c) { return !std::isalpha(c) || std::isupper(c); });
        new_stem = change_case_str(new_stem, has_upper);
    }

    return new_stem + ext;
}

}  // namespace

auto MultiRename::preview(const std::vector<std::string>& files, const RenameRule& rule)
    -> std::vector<RenamePreview> {
    std::vector<RenamePreview> result;
    result.reserve(files.size());

    for (std::size_t i = 0; i < files.size(); ++i) {
        const std::filesystem::path full_path(files[i]);
        const std::string original_name = full_path.filename().string();
        const std::string new_name = apply_rule(original_name, rule, i);

        RenamePreview preview_item;
        preview_item.original = original_name;
        preview_item.renamed = new_name;
        result.push_back(std::move(preview_item));
    }

    return result;
}

auto MultiRename::execute(const std::vector<std::string>& files, const RenameRule& rule)
    -> common::Result<void> {
    if (files.empty()) {
        return common::Result<void>();
    }

    // First pass: compute all new names and check for conflicts
    std::vector<std::pair<std::filesystem::path, std::filesystem::path>> renames;
    renames.reserve(files.size());

    for (std::size_t i = 0; i < files.size(); ++i) {
        const std::filesystem::path full_path(files[i]);
        const std::string new_name = apply_rule(full_path.filename().string(), rule, i);
        const std::filesystem::path new_path = full_path.parent_path() / new_name;

        if (full_path != new_path) {
            renames.emplace_back(full_path, new_path);
        }
    }

    // Check for destination conflicts — both with existing files on disk AND collisions
    // WITHIN the batch. Two files renamed to the same target (e.g. a rule that strips digits:
    // a1.txt + a2.txt → a.txt) would silently overwrite each other and lose a file.
    std::unordered_set<std::string> destination_set;
    for (const auto& [src, dst] : renames) {
        if (!destination_set.insert(dst.string()).second) {
            return common::Error::make(common::ErrorCode::AlreadyExists,
                                       "Two files would be renamed to the same name",
                                       dst.string());
        }
        std::error_code ec;
        if (std::filesystem::exists(dst, ec) && src != dst) {
            return common::Error::make(common::ErrorCode::AlreadyExists,
                                       "Destination already exists",
                                       dst.string());
        }
    }

    // Second pass: execute renames
    for (const auto& [src, dst] : renames) {
        std::error_code ec;
        std::filesystem::rename(src, dst, ec);
        if (ec) {
            return common::Error::make(common::ErrorCode::IOError,
                                       "Failed to rename file: " + ec.message(),
                                       src.string());
        }
    }

    return common::Result<void>();
}

}  // namespace fcxl::tools
