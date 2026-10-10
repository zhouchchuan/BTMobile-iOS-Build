#include "../entry/src/main/cpp/bt_settings.hpp"
#include "../entry/src/main/cpp/network_access.hpp"
#include <cassert>
#include <iostream>
int main() {
    using namespace btmobile;
    auto defaults = defaultSettings();
    assert(defaults["listenPort"] == 6882 && defaults["queueEnabled"] == false && defaults["seedEnabled"] == true);
    for (auto key : {"dht","lsd","upnp","natPmp","utp","autoAddTrackers","allowWifi","allowCellular","completionNotifications"}) assert(defaults[key] == true);
    for (bool w : {false,true}) for (bool c : {false,true}) {
        assert(transferAllowed(w,c,true,true,false,false) == w);
        assert(transferAllowed(w,c,true,false,true,false) == c);
        assert(transferAllowed(w,c,true,true,true,false) == (w && c));
        assert(transferAllowed(w,c,false,false,false,false) == (w && c));
        assert(transferAllowed(w,c,true,false,false,true) == (w && c));
    }
    auto changed = validateSettings(defaults, {{"uploadLimitKiB",512},{"queueEnabled",true},{"maxSeeds",0},
        {"customTrackers",{"  udp://example.org:6969/announce  ","udp://example.org:6969/announce","https://example.org/announce"}}});
    assert(changed["customTrackers"].size() == 2 && changed["uploadLimitKiB"] == 512 && changed["downloadLimitKiB"] == 0);
    assert(defaults["uploadLimitKiB"] == 0);
    for (auto invalid : std::vector<json>{ {{"listenPort",0}}, {{"listenPort",65536}}, {{"downloadLimitKiB",-1}},
        {{"uploadLimitKiB",1.5}}, {{"maxActive",1001}}, {{"dht","true"}}, {{"unknown",0}},
        {{"allowWifi",1}}, {{"allowCellular","false"}}, {{"completionNotifications",0}},
        {{"customTrackers",{"file:///tmp/test"}}}, {{"customTrackers",{"udp://"}}},
        {{"customTrackers",{"https://foo bar/announce"}}}, {{"customTrackers",{"https://user:pw@host/announce"}}} }) {
        bool rejected = false; try { validateSettings(defaults, invalid); } catch (std::exception const&) { rejected = true; }
        assert(rejected);
    }
    assert(defaultTrackers().size() == 9);
    std::cout << "PASS settings: defaults, partial update, bounds, URL validation, deduplication\n";
}
