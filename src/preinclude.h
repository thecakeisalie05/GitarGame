#pragma once
#include <algorithm>
#include <cctype>
#include <iterator>
#include <string>

inline std::string upper(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) {
        return static_cast<char>(std::toupper(c));
    });
    return s;
}
