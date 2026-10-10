#pragma once
#include <nlohmann/json.hpp>
#include <algorithm>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>

namespace btmobile {
using json = nlohmann::json;
inline std::vector<std::string> defaultTrackers() {
    return {"http://tracker1.linkyou.win:6969/announce", "http://tracker2.linkyou.win:6969/announce",
        "http://tracker2v4.linkyou.win:6969/announce", "http://tracker2v6.linkyou.win:6969/announce",
        "udp://open.stealth.si:80/announce", "udp://retracker.hotplug.ru:2710/announce",
        "udp://tracker.torrent.eu.org:451/announce", "udp://tracker.tryhackx.org:6969/announce",
        "udp://www.torrent.eu.org:451/announce"};
}
inline json defaultSettings() {
    return {{"listenPort",6882},{"dht",true},{"lsd",true},{"natPmp",true},{"upnp",true},{"utp",true},
        {"downloadLimitKiB",0},{"uploadLimitKiB",0},{"queueEnabled",false},{"maxActive",8},
        {"maxDownloads",3},{"maxSeeds",5},{"seedEnabled",true},{"autoAddTrackers",true},{"customTrackers",json::array()},
        {"allowWifi",true},{"allowCellular",true},{"completionNotifications",true}};
}
inline json validateSettings(json current, json const& changes) {
    if (!changes.is_object()) throw std::runtime_error("设置格式无效");
    for (auto const& item : changes.items()) {
        if (!current.contains(item.key())) throw std::runtime_error("未知设置项");
        current[item.key()] = item.value();
    }
    auto integer = [&](char const* key, int low, int high, char const* message) {
        if (!current[key].is_number_integer() || current[key] < low || current[key] > high)
            throw std::runtime_error(message);
    };
    integer("listenPort",1024,65535,"BT 端口必须是 1024 到 65535 的整数");
    for (auto key : {"downloadLimitKiB","uploadLimitKiB"}) integer(key,0,1048576,"限速必须是 0 到 1048576 的整数（KiB/s），0 表示不限速");
    for (auto key : {"maxActive","maxDownloads","maxSeeds"}) integer(key,0,1000,"队列数量必须是 0 到 1000 的整数，0 表示该类任务全部等待");
    for (auto key : {"dht","lsd","natPmp","upnp","utp","queueEnabled","seedEnabled","autoAddTrackers","allowWifi","allowCellular","completionNotifications"})
        if (!current[key].is_boolean()) throw std::runtime_error("开关设置无效");
    if (!current["customTrackers"].is_array() || current["customTrackers"].size() > 200)
        throw std::runtime_error("自定义 Tracker 最多 200 个，每行一个地址");
    json urls = json::array(); std::set<std::string> seen;
    for (auto const& value : current["customTrackers"]) {
        if (!value.is_string()) throw std::runtime_error("Tracker 地址必须是文本");
        std::string url = value.get<std::string>();
        auto first = url.find_first_not_of(" \t\r\n"); if (first == url.npos) continue;
        url = url.substr(first, url.find_last_not_of(" \t\r\n") - first + 1);
        auto scheme = url.find("://");
        if (url.size() > 2048 || scheme == url.npos || (url.substr(0,scheme) != "http" && url.substr(0,scheme) != "https" && url.substr(0,scheme) != "udp"))
            throw std::runtime_error("Tracker 仅支持 http://、https:// 和 udp:// 地址");
        auto end = url.find('/',scheme+3); auto authority = url.substr(scheme+3, end == url.npos ? end : end-scheme-3);
        if (authority.empty() || authority.front() == ':' || authority.find('@') != authority.npos ||
            url.find('#') != url.npos || std::any_of(url.begin(),url.end(),[](unsigned char c){return c <= 32 || c == 127;}))
            throw std::runtime_error("Tracker 地址格式无效，请每行填写一个完整地址");
        if (seen.insert(url).second) urls.push_back(url);
    }
    current["customTrackers"] = urls;
    return current;
}
}
