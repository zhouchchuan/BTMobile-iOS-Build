#pragma once
#include <algorithm>
#include <charconv>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <filesystem>

struct ByteRange { int64_t start, end; bool partial; };
inline std::optional<ByteRange> parseRange(std::string_view s, int64_t size) {
    if (size <= 0) return {};
    if (s.empty()) return ByteRange{0, size - 1, false};
    if (s.substr(0, 6) != "bytes=" || s.find(',') != s.npos) return {};
    s.remove_prefix(6);
    auto dash = s.find('-');
    if (dash == s.npos) return {};
    auto number = [](std::string_view v) -> std::optional<int64_t> {
        if (v.empty() || v.find_first_not_of("0123456789") != v.npos) return {};
        int64_t n = 0; auto r = std::from_chars(v.data(), v.data() + v.size(), n);
        if (r.ec != std::errc{} || r.ptr != v.data() + v.size()) return {};
        return n;
    };
    if (dash == 0) {
        auto n = number(s.substr(1));
        if (!n || *n == 0) return {};
        return ByteRange{std::max(int64_t(0), size - *n), size - 1, true};
    }
    auto start = number(s.substr(0, dash));
    if (!start || *start >= size) return {};
    int64_t end = size - 1;
    if (dash + 1 < s.size()) {
        auto n = number(s.substr(dash + 1));
        if (!n || *n < *start) return {};
        end = std::min(end, *n);
    }
    return ByteRange{*start, end, true};
}
inline bool safeArchivePath(std::string const& name) {
    if (name.empty() || name[0] == '/' || name[0] == '\\' || name.find(':') != name.npos || name.find('\0') != name.npos) return false;
    std::string clean = name; std::replace(clean.begin(), clean.end(), '\\', '/');
    for (auto const& p : std::filesystem::path(clean)) if (p == "..") return false;
    return true;
}
