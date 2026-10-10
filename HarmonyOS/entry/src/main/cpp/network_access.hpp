#pragma once

namespace btmobile {
// Restricted mode requires a positively identified default bearer. Never
// enumerate alternate networks or bypass a VPN to find an allowed interface.
inline bool transferAllowed(bool wifiAllowed, bool cellularAllowed, bool known,
    bool wifi, bool cellular, bool other) {
    if (wifiAllowed && cellularAllowed) return true; // Preserve existing routing.
    if (!wifiAllowed && !cellularAllowed) return false;
    if (!known || other || (!wifi && !cellular)) return false;
    return (!wifi || wifiAllowed) && (!cellular || cellularAllowed);
}
}
