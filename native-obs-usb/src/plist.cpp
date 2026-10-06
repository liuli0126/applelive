#include "plist.h"

#include <algorithm>
#include <cstring>
#include <cctype>
#include <stdexcept>

namespace applelive::plist {

namespace {

std::string escape(const std::string &value)
{
    std::string out;
    for (char c : value) {
        if (c == '&') out += "&amp;";
        else if (c == '<') out += "&lt;";
        else if (c == '>') out += "&gt;";
        else out += c;
    }
    return out;
}

void append_xml(std::string &out, const Value &value)
{
    switch (value.type) {
    case Value::Type::Integer: out += "<integer>" + std::to_string(value.integer) + "</integer>"; break;
    case Value::Type::String: out += "<string>" + escape(value.string) + "</string>"; break;
    case Value::Type::Dict:
        out += "<dict>";
        for (const auto &[key, child] : value.dict) {
            out += "<key>" + escape(key) + "</key>";
            append_xml(out, child);
        }
        out += "</dict>";
        break;
    case Value::Type::Array:
        out += "<array>";
        for (const auto &child : value.array) append_xml(out, child);
        out += "</array>";
        break;
    default: out += "<string></string>"; break;
    }
}

class BinaryReader {
public:
    explicit BinaryReader(const std::vector<std::uint8_t> &input) : bytes(input) {}
    bool run(Value &output)
    {
        if (bytes.size() < 40 || std::memcmp(bytes.data(), "bplist00", 8) != 0) return false;
        const std::size_t trailer = bytes.size() - 32;
        offset_size = bytes[trailer + 6];
        ref_size = bytes[trailer + 7];
        objects = integer(trailer + 8, 8);
        top = integer(trailer + 16, 8);
        offsets = integer(trailer + 24, 8);
        if (!offset_size || offset_size > 8 || !ref_size || ref_size > 8 || !objects ||
            objects > 4096 || offsets >= trailer || objects > (trailer - offsets) / offset_size || top >= objects) return false;
        return object(top, output);
    }

private:
    const std::vector<std::uint8_t> &bytes;
    std::size_t offset_size = 0, ref_size = 0, objects = 0, top = 0, offsets = 0;

    std::uint64_t integer(std::size_t at, std::size_t count) const
    {
        if (at > bytes.size() || count > bytes.size() - at || count > 8) return 0;
        std::uint64_t value = 0;
        for (std::size_t i = 0; i < count; ++i) value = (value << 8) | bytes[at + i];
        return value;
    }
    bool ref(std::size_t at, std::size_t &value) const
    {
        if (at > bytes.size() || ref_size > bytes.size() - at) return false;
        value = static_cast<std::size_t>(integer(at, ref_size));
        return value < objects;
    }
    bool length(std::size_t &at, std::size_t info, std::size_t &value) const
    {
        if (info != 0x0f) { value = info; return true; }
        if (at >= bytes.size()) return false;
        const std::uint8_t marker = bytes[at++];
        if ((marker >> 4) != 0x1) return false;
        const std::size_t count = std::size_t(1) << (marker & 0x0f);
        if (count > 8 || at + count > bytes.size()) return false;
        value = static_cast<std::size_t>(integer(at, count));
        at += count;
        return true;
    }
    std::size_t budget = 8192;
    bool object(std::size_t index, Value &value, unsigned depth = 0)
    {
        if (depth > 32 || !budget--) return false;
        const std::size_t table = offsets + index * offset_size;
        if (table + offset_size > bytes.size()) return false;
        std::size_t at = static_cast<std::size_t>(integer(table, offset_size));
        if (at >= bytes.size()) return false;
        const std::uint8_t marker = bytes[at++];
        const std::uint8_t type = marker >> 4;
        std::size_t count = 0;
        if (type == 0x0) { value.type = Value::Type::Null; return true; }
        if (type == 0x1) {
            count = std::size_t(1) << (marker & 0x0f);
            if (count > 8 || at + count > bytes.size()) return false;
            value.type = Value::Type::Integer;
            value.integer = integer(at, count);
            return true;
        }
        if (type == 0x4 || type == 0x5 || type == 0x6) {
            if (!length(at, marker & 0x0f, count) || count > (bytes.size() - at) / (type == 0x6 ? 2 : 1)) return false;
            if (type == 0x4) { value.type = Value::Type::Null; return true; }
            value.type = Value::Type::String;
            if (type == 0x5) value.string.assign(reinterpret_cast<const char *>(bytes.data() + at), count);
            else {
                for (std::size_t i = 0; i < count; ++i) {
                    const std::uint16_t ch = static_cast<std::uint16_t>(bytes[at + 2 * i] << 8 | bytes[at + 2 * i + 1]);
                    value.string += ch < 128 ? static_cast<char>(ch) : '?';
                }
            }
            return true;
        }
        if (type == 0xa || type == 0xd) {
            if (!length(at, marker & 0x0f, count) || count > 4096) return false;
            const std::size_t refs = type == 0xd ? count * 2 : count;
            if (at + refs * ref_size > bytes.size()) return false;
            if (type == 0xa) {
                value.type = Value::Type::Array;
                for (std::size_t i = 0; i < count; ++i) {
                    std::size_t child = 0;
                    if (!ref(at + i * ref_size, child)) return false;
                    Value item;
                    if (!object(child, item, depth + 1)) return false;
                    value.array.push_back(std::move(item));
                }
            } else {
                value.type = Value::Type::Dict;
                for (std::size_t i = 0; i < count; ++i) {
                    std::size_t key = 0, child = 0;
                    if (!ref(at + i * ref_size, key) || !ref(at + (count + i) * ref_size, child)) return false;
                    Value key_value, item;
                    if (!object(key, key_value, depth + 1) || !object(child, item, depth + 1) || key_value.type != Value::Type::String) return false;
                    value.dict.emplace(key_value.string, std::move(item));
                }
            }
            return true;
        }
        return false;
    }
};

// usbmuxd commonly replies with XML even though binary plists are also valid.
// This bounded parser does not resolve DTDs, external entities, or resources.
class XMLReader {
    std::string text;
    size_t pos = 0, budget = 8192;
    void space() { while (pos < text.size() && std::isspace(static_cast<unsigned char>(text[pos]))) ++pos; }
    bool take(const std::string &token) {
        space();
        if (text.compare(pos, token.size(), token)) return false;
        pos += token.size(); return true;
    }
    bool content(const char *tag, std::string &out) {
        if (!take(std::string("<") + tag + ">")) return false;
        std::string end = std::string("</") + tag + ">";
        size_t last = text.find(end, pos);
        if (last == std::string::npos) return false;
        out = text.substr(pos, last - pos); pos = last + end.size();
        for (auto pair : {std::pair<const char *, const char *>("&lt;", "<"), {"&gt;", ">"}, {"&quot;", "\""}, {"&apos;", "'"}, {"&amp;", "&"}}) {
            size_t at = 0;
            while ((at = out.find(pair.first, at)) != std::string::npos) { out.replace(at, strlen(pair.first), pair.second); ++at; }
        }
        return true;
    }
    bool value(Value &v, unsigned depth) {
        if (depth > 32 || !budget--) return false;
        if (take("<dict/>")) { v.type = Value::Type::Dict; return true; }
        if (take("<array/>")) { v.type = Value::Type::Array; return true; }
        if (take("<dict>")) {
            v.type = Value::Type::Dict;
            while (!take("</dict>")) {
                std::string key; Value child;
                if (!content("key", key) || !value(child, depth + 1)) return false;
                v.dict.emplace(std::move(key), std::move(child));
            }
            return true;
        }
        if (take("<array>")) {
            v.type = Value::Type::Array;
            while (!take("</array>")) {
                Value child; if (!value(child, depth + 1)) return false;
                v.array.push_back(std::move(child));
            }
            return true;
        }
        std::string item;
        if (take("<string/>")) { v.type = Value::Type::String; return true; }
        if (content("string", item)) { v.type = Value::Type::String; v.string = item; return true; }
        if (content("integer", item)) {
            try {
                size_t used; auto number = std::stoull(item, &used, 10);
                if (used != item.size()) return false;
                v.type = Value::Type::Integer; v.integer = number; return true;
            } catch (...) { return false; }
        }
        if (take("<true/>") || take("<false/>") || take("<data/>") || content("data", item) || content("real", item) || content("date", item)) { v.type = Value::Type::Null; return true; }
        return false;
    }
public:
    explicit XMLReader(const std::vector<std::uint8_t> &input) : text(input.begin(), input.end()) {}
    bool run(Value &out) {
        // Only skip the XML declaration and the standard plist DOCTYPE. No I/O.
        space();
        if (text.compare(pos, 2, "<?") == 0) { auto end = text.find("?>", pos); if (end == std::string::npos) return false; pos = end + 2; }
        space();
        if (text.compare(pos, 9, "<!DOCTYPE") == 0) { auto end = text.find('>', pos); if (end == std::string::npos || text.substr(pos, end-pos).find('[') != std::string::npos) return false; pos = end + 1; }
        space();
        if (text.compare(pos, 6, "<plist") != 0) return false;
        auto end = text.find('>', pos); if (end == std::string::npos) return false; pos = end + 1;
        if (!value(out, 0) || !take("</plist>")) return false;
        space(); return pos == text.size();
    }
};

} // namespace

std::string xml_request(const std::map<std::string, Value> &dict)
{
    Value root;
    root.type = Value::Type::Dict;
    root.dict = dict;
    std::string result = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\">";
    append_xml(result, root);
    result += "</plist>";
    return result;
}

bool parse(const std::vector<std::uint8_t> &bytes, Value &value)
{
    if (bytes.size() > 1024 * 1024) return false;
    if (bytes.size() >= 8 && memcmp(bytes.data(), "bplist00", 8) == 0) return BinaryReader(bytes).run(value);
    return XMLReader(bytes).run(value);
}

const Value *get(const Value &value, const std::string &key)
{
    if (value.type != Value::Type::Dict) return nullptr;
    const auto found = value.dict.find(key);
    return found == value.dict.end() ? nullptr : &found->second;
}

} // namespace applelive::plist
