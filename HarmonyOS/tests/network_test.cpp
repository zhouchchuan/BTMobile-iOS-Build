#define BT_MOBILE_NETWORK_TEST
#include "../entry/src/main/cpp/ohos_network.hpp"
#include <cassert>
#include <iostream>

static int mockCode = 0, mockAvailable = 1;
static NetConn_ConnectionProperties mockProperties{};
static NetConn_NetCapabilities mockCapabilities{};
static int mockCapabilitiesCode = 0;
extern "C" int32_t OH_NetConn_HasDefaultNet(int32_t* out) { *out = mockAvailable; return mockCode; }
extern "C" int32_t OH_NetConn_GetDefaultNet(NetConn_NetHandle* out) { out->netId = 42; return 0; }
extern "C" int32_t OH_NetConn_GetConnectionProperties(NetConn_NetHandle*, NetConn_ConnectionProperties* out) { *out = mockProperties; return 0; }
extern "C" int32_t OH_NetConn_GetNetCapabilities(NetConn_NetHandle*, NetConn_NetCapabilities* out) { *out = mockCapabilities; return mockCapabilitiesCode; }
int main() {
    using namespace btmobile_ohos;
    auto& p = mockProperties;
    mockCapabilities.bearerTypesSize = 1; mockCapabilities.bearerTypes[0] = NETCONN_BEARER_WIFI;
    copyName(p.ifaceName, "wlan0"); p.mtu = 1500;
    p.netAddrListSize = 2;
    copyName(p.netAddrList[0].address, "192.0.2.10"); p.netAddrList[0].prefixlen = 24;
    copyName(p.netAddrList[1].address, "2001:db8::10"); p.netAddrList[1].prefixlen = 64;
    p.routeListSize = 2;
    copyName(p.routeList[0].destination.address, "0.0.0.0");
    copyName(p.routeList[0].gateway.address, "192.0.2.1"); p.routeList[0].hasGateway = 1;
    copyName(p.routeList[1].destination.address, "::");
    copyName(p.routeList[1].gateway.address, "fe80::1"); p.routeList[1].hasGateway = 1;
    auto n = snapshot();
    assert(n.code == 0 && n.netId == 42 && n.interfaces.size() == 2 && n.routes.size() == 2);
    assert(n.bearerKnown && n.wifi && !n.cellular && !n.otherBearer && n.iface == "wlan0");
    mockCapabilities.bearerTypes[0] = NETCONN_BEARER_CELLULAR;
    assert(snapshot().cellular && !snapshot().wifi && snapshot().identity != n.identity);
    mockCapabilities.bearerTypes[0] = NETCONN_BEARER_VPN;
    assert(snapshot().otherBearer && !snapshot().wifi);
    mockCapabilitiesCode = 201; assert(!snapshot().bearerKnown && snapshot().code == 0);
    mockCapabilitiesCode = 0; mockCapabilities.bearerTypes[0] = NETCONN_BEARER_WIFI;
    assert(n.interfaces[0].netmask.to_string() == "255.255.255.0");
    assert(n.interfaces[1].netmask.to_string() == "ffff:ffff:ffff:ffff::");
    assert(lt::aux::has_internet_route("wlan0", AF_INET, n.routes));
    assert(lt::aux::has_internet_route("wlan0", AF_INET6, n.routes));
    assert(!lt::aux::has_internet_route("other0", AF_INET, n.routes));
    std::swap(p.netAddrList[0], p.netAddrList[1]); assert(snapshot().identity == n.identity);
    // A default VPN is the only source. Foreign route interfaces are discarded.
    copyName(p.ifaceName, "tun0"); copyName(p.routeList[0].iface, "wlan0");
    n = snapshot(); assert(n.interfaces.size() == 2 && n.routes.size() == 1);
    assert(!lt::aux::has_internet_route("wlan0", AF_INET, n.routes));
    p.netAddrList[0].prefixlen = 255; copyName(p.netAddrList[1].address, "invalid");
    assert(snapshot().code == -2);
    p.netAddrListSize = -1; p.routeListSize = -1; assert(snapshot().interfaces.empty());
    mockCode = 201; lt::error_code ec; assert(interfaces(ec).empty() && ec.value() == EACCES);
    mockCode = 0; mockAvailable = 0; assert(snapshot().code == -1);
    std::cout << "PASS: SDK IPv4/IPv6 conversion, route classification, VPN isolation, stable network identity, denied/offline/malformed inputs\n";
}
