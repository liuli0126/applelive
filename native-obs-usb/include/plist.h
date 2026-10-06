#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace applelive::plist {

struct Value {
    enum class Type { Null, Integer, String, Dict, Array } type = Type::Null;
    std::uint64_t integer = 0;
    std::string string;
    std::map<std::string, Value> dict;
    std::vector<Value> array;
};

std::string xml_request(const std::map<std::string, Value> &dict);
bool parse(const std::vector<std::uint8_t> &bytes, Value &value);
const Value *get(const Value &value, const std::string &key);

} // namespace applelive::plist
