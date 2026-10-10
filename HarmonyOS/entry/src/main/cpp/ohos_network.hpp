#pragma once

// HarmonyOS application sandboxes cannot enumerate Linux NETLINK_ROUTE.
// Use NetworkKit's default network only (including its VPN), never bypass it
// by enumerating other bearers. These APIs are available since API 11.
#ifdef BT_MOBILE_NETWORK_TEST
#include <network/netmanager/net_connection_type.h>
extern "C" {
int32_t OH_NetConn_HasDefaultNet(int32_t*);
int32_t OH_NetConn_GetDefaultNet(NetConn_NetHandle*);
int32_t OH_NetConn_GetConnectionProperties(NetConn_NetHandle*, NetConn_ConnectionProperties*);
int32_t OH_NetConn_GetNetCapabilities(NetConn_NetHandle*, NetConn_NetCapabilities*);
}
#else
#include <network/netmanager/net_connection.h>
#endif
#include <libtorrent/aux_/enum_net.hpp>
#include <algorithm>
#include <cstring>
#include <memory>
#include <net/if.h>
#include <set>

namespace btmobile_ohos {
namespace lt = libtorrent;

struct Network {
    int code = 0;
    int netId = 0;
    std::vector<lt::aux::ip_interface> interfaces;
    std::vector<lt::aux::ip_route> routes;
    std::string identity;
    std::string iface;
    bool bearerKnown = false, wifi = false, cellular = false, otherBearer = false;
};

template <size_t N> inline std::string bounded(char const (&value)[N]) {
    return std::string(value, strnlen(value, N));
}
template <size_t N> inline void copyName(char (&out)[N], std::string const& value) {
    std::strncpy(out, value.c_str(), N - 1); out[N - 1] = '\0';
}
inline lt::address address(NetConn_NetAddr const& raw, std::string const& iface, lt::error_code& ec) {
    auto result = lt::make_address(bounded(raw.address), ec);
    if (!ec && result.is_v6() && result.to_v6().is_link_local() && result.to_v6().scope_id() == 0) {
        auto v6 = result.to_v6(); v6.scope_id(if_nametoindex(iface.c_str())); result = v6;
    }
    return result;
}

// Pure conversion is exercised with the SDK's own structures in host tests.
inline Network convert(NetConn_ConnectionProperties const& prop, int netId) {
    Network result; result.netId = netId;
    const auto iface = bounded(prop.ifaceName);
    result.iface = iface;
    if (iface.empty()) { result.code = -2; return result; }
    std::set<std::string> identities;
    for (int i = 0; i < std::clamp(prop.netAddrListSize, 0, NETCONN_MAX_ADDR_SIZE); ++i) {
        auto const& raw = prop.netAddrList[i]; lt::error_code ec;
        auto ip = address(raw, iface, ec);
        if (ec || ip.is_unspecified() || ip.is_loopback() || raw.prefixlen > (ip.is_v4() ? 32 : 128)) continue;
        lt::aux::ip_interface item;
        item.interface_address = ip;
        item.netmask = lt::aux::build_netmask(raw.prefixlen, ip.is_v4() ? AF_INET : AF_INET6);
        item.flags = lt::aux::if_flags::up | lt::aux::if_flags::running;
        item.state = lt::aux::if_state::up;
        copyName(item.name, iface); copyName(item.friendly_name, iface);
        if (identities.insert(ip.to_string()).second) result.interfaces.push_back(item);
    }
    for (int i = 0; i < std::clamp(prop.routeListSize, 0, NETCONN_MAX_ROUTE_SIZE); ++i) {
        auto const& raw = prop.routeList[i]; lt::error_code ec;
        auto routeIface = bounded(raw.iface);
        if (routeIface.empty()) routeIface = iface;
        if (routeIface != iface) continue;
        auto destination = address(raw.destination, iface, ec);
        if (ec || raw.destination.prefixlen > (destination.is_v4() ? 32 : 128)) continue;
        lt::aux::ip_route item;
        item.destination = destination;
        item.netmask = lt::aux::build_netmask(raw.destination.prefixlen, destination.is_v4() ? AF_INET : AF_INET6);
        item.gateway = destination.is_v4() ? lt::address(lt::address_v4::any()) : lt::address(lt::address_v6::any());
        if (raw.hasGateway) {
            item.gateway = address(raw.gateway, iface, ec);
            if (ec || item.gateway.is_v4() != destination.is_v4()) continue;
        }
        item.source_hint = destination.is_v4() ? lt::address(lt::address_v4::any()) : lt::address(lt::address_v6::any());
        copyName(item.name, iface); item.mtu = prop.mtu;
        result.routes.push_back(item);
        identities.insert(destination.to_string() + "/" + std::to_string(raw.destination.prefixlen) + ":" + item.gateway.to_string());
    }
    result.identity = std::to_string(netId) + ":" + iface;
    for (auto const& value : identities) result.identity += ";" + value;
    if (result.interfaces.empty()) result.code = -2;
    return result;
}
inline Network snapshot() {
    Network result; int32_t available = 0;
    result.code = OH_NetConn_HasDefaultNet(&available);
    if (result.code) return result;
    if (!available) { result.code = -1; return result; }
    NetConn_NetHandle handle{};
    result.code = OH_NetConn_GetDefaultNet(&handle);
    if (result.code) return result;
    auto prop = std::make_unique<NetConn_ConnectionProperties>();
    result.code = OH_NetConn_GetConnectionProperties(&handle, prop.get());
    if (result.code) return result;
    result = convert(*prop, handle.netId);
    NetConn_NetCapabilities caps{};
    if (OH_NetConn_GetNetCapabilities(&handle, &caps) == 0 && caps.bearerTypesSize > 0 &&
        caps.bearerTypesSize <= int(sizeof(caps.bearerTypes) / sizeof(caps.bearerTypes[0]))) {
        result.bearerKnown = true;
        for (int i = 0; i < caps.bearerTypesSize; ++i) {
            if (caps.bearerTypes[i] == NETCONN_BEARER_WIFI) result.wifi = true;
            else if (caps.bearerTypes[i] == NETCONN_BEARER_CELLULAR) result.cellular = true;
            else result.otherBearer = true;
        }
    }
    result.identity += ":bearers:" + std::to_string(result.bearerKnown) + std::to_string(result.wifi) +
        std::to_string(result.cellular) + std::to_string(result.otherBearer);
    return result;
}
inline std::vector<lt::aux::ip_interface> interfaces(lt::error_code& ec) {
    auto network = snapshot(); ec.clear();
    if (network.code) ec = lt::error_code(network.code == 201 ? EACCES : ENETDOWN, lt::generic_category());
    return network.interfaces;
}
inline std::vector<lt::aux::ip_route> routes(lt::error_code& ec) {
    auto network = snapshot(); ec.clear();
    if (network.code) ec = lt::error_code(network.code == 201 ? EACCES : ENETDOWN, lt::generic_category());
    return network.routes;
}
}
