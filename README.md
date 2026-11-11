# LainBridge 0.1.0 (rootless, arm64, iOS 15+)

Pane in Settings -> LainBridge. Two menus:

* menu 1 // wired chain: 14 Pro Max hotspot -> 6s (wifi) -> hotspot -> clients
* menu 2 // sim relay: SIM in the 6s -> hotspot -> clients

Install: push this folder to a GitHub repo, wait for the Actions build, download the
`LainBridge-deb` artifact, install the .deb (needs `preferenceloader`). Hotspot without a SIM: also install the Share tweak.

Use: Settings -> LainBridge -> pick mode -> [ apply ] -> turn the hotspot on in Settings ->
[ check connection ] -> [ copy full log ] and paste the log to me.

The daemon (`lainbridged`) logs every method it tries (sysctl TTL, pf scrub min-ttl in two anchors and two syntaxes,
NAT out of en0, rejoin of uplink wifi through MobileWiFi). Nothing here is tested on a real 6s yet:
the log is how we find out which method broke.
