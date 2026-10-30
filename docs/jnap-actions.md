# JNAP actions on a tested router

This is the action catalog a Pinnacle 2.2 **M62CF-EU** (firmware 1.2.4) advertised to its web app. Other Velop and Pinnacle builds overlap, but they are not the same list. MeshBar calls only the subset described in the README.

Requests are `POST https://<router>/JNAP/` with `X-JNAP-Action: http://linksys.com/jnap/<service>/<Action>`.

## core

CheckAdminPassword, CheckAdminPassword2, CheckAdminPassword3, FactoryReset, FactoryReset2, GetAdminPasswordAuthStatus, GetAdminPasswordHint, GetDataUploadUserConsent, GetDeviceInfo, GetUnsecuredWiFiWarning, IsAdminPasswordDefault, IsServiceSupported, Reboot, Reboot2, SetAdminPassword, SetAdminPassword2, SetAdminPassword3, SetUnsecuredWiFiWarning

## ddns

GetDDNSSettings, GetDDNSStatus, GetDDNSStatus2, GetSupportedDDNSProviders, SetDDNSSettings

## devicelist

DeleteDevice, GetDevices, GetDevices3, GetLocalDevice, SetDeviceProperties

## diagnostics

GetPingStatus, GetSysinfoData, GetSystemStats, GetSystemStats2, GetTracerouteStatus, StartPing, StartTraceroute, StopPing, StopTraceroute

## firewall

GetALGSettings, GetDMZSettings, GetFirewallSettings, GetIPv6FirewallRules, GetPortRangeForwardingRules, GetPortRangeTriggeringRules, GetSinglePortForwardingRules, SetALGSettings, SetDMZSettings, SetFirewallSettings, SetIPv6FirewallRules, SetPortRangeForwardingRules, SetPortRangeTriggeringRules, SetSinglePortForwardingRules

## firmwareupdate

GetFirmwareUpdateSettings, GetFirmwareUpdateStatus, SetFirmwareUpdateSettings

## gamingprioritization

GetGamingPrioritizationSettings, SetGamingPrioritizationSettings

## guestnetwork

GetGuestNetworkClients, GetGuestNetworkSettings, GetGuestNetworkSettings2, GetGuestRadioSettings, GetGuestRadioSettings2, SetGuestNetworkSettings, SetGuestNetworkSettings3, SetGuestRadioSettings, SetGuestRadioSettings2

## healthcheck

ClearHealthCheckHistory, GetCloseHealthCheckServers, GetHealthCheckResults, GetHealthCheckStatus, GetSupportedHealthCheckModules, RunHealthCheck, StopHealthCheck

## iptv

GetIPTVSettings, SetIPTVSettings

## locale

GetLocalTime, GetLocale, GetTimeSettings, SetLocale, SetTimeSettings

## macfilter

GetMACFilterSettings, GetSTABSSIDS, SetMACFilterSettings

## motionsensing

GetActiveMotionSensingBots, GetMotionSensingSettings

## networkconnections

GetNetworkConnections, GetNetworkConnections2

## networksecurity

GetNetworkSecuritySettings, GetNetworkSecuritySettings2, SetNetworkSecuritySettings, SetNetworkSecuritySettings2

## nodes/autoonboarding

GetBluetoothAutoOnboardingSettings, GetBluetoothAutoOnboardingStatus, GetBluetoothAutoOnboardingStatus2, GetWiredAutoOnboardingSettings, SetBluetoothAutoOnboardingSettings, SetWiredAutoOnboardingSettings, StartBluetoothAutoOnboarding, StartBluetoothAutoOnboarding2

## nodes/diagnostics

GetBackhaulInfo, GetBackhaulInfo2, GetNodeNeighborInfo, GetSlaveBackhaulStatus, RefreshSlaveBackhaulData

## nodes/firmwareupdate

GetFirmwareUpdateStatus, UpdateFirmwareNow

## nodes/networkconnections

GetNodesWirelessNetworkConnections, GetNodesWirelessNetworkConnections2

## nodes/setup

GetAutoConfigurationSettings, GetAutoMasterStatus, GetInternetConnectionStatus, GetMACAddress, GetPortConnectionStatus, GetSelectedChannels, GetSimpleWiFiSettings, GetVersionInfo, GetWANDetectionStatus, GetWANPort, IsAdminPasswordSetByUser, SetAdminPassword, SetAdminPassword2, SetSimpleWiFiSettings, SetUserAcknowledgedAutoConfiguration, SetWANPort, Setup, Setup10, Setup11, Setup2, Setup3, Setup4, Setup5, Setup6, Setup7, Setup8, Setup9, StartAutoChannelSelection, StartBlinkingNodeLed, StopBlinkingNodeLed

## nodes/smartconnect

GetSmartConnectPIN, GetSmartConnectStatus

## nodes/smartmode

GetDeviceMode, GetSupportedDeviceModes, SetDeviceMode

## nodes/topologyoptimization

GetTopologyOptimizationSettings, GetTopologyOptimizationSettings2, SetTopologyOptimizationSettings, SetTopologyOptimizationSettings2

## ownednetwork

GetOwnedNetworkID, IsOwnedNetwork, SetNetworkOwner

## parentalcontrol

GetParentalControlSettings

## powertable

GetPowerTableSettings, SetPowerTableSettings

## product

GetSoftSKUSettings

## qos

GetQoSSettings, GetQoSSettings2

## router

GetDHCPClientLeases, GetEthernetPortConnections, GetExpressForwardingSettings, GetIPv6Settings, GetIPv6Settings2, GetLANSettings, GetMACAddressCloneSettings, GetRoutingSettings, GetWANExternal, GetWANSettings, GetWANSettings2, GetWANSettings3, GetWANSettings4, GetWANSettings5, GetWANStatus, GetWANStatus2, GetWANStatus3, SetExpressForwardingSettings, SetIPv6Settings, SetIPv6Settings2, SetLANSettings, SetMACAddressCloneSettings, SetRoutingSettings, SetWANSettings, SetWANSettings2, SetWANSettings3, SetWANSettings4, SetWANSettings5

## routerleds

GetLedNightModeSetting, SetLedNightModeSetting, SetLedNightModeSetting2

## routermanagement

GetManagementSettings, GetManagementSettings2, SetManagementSettings, SetManagementSettings2

## routerupnp

GetUPnPSettings, SetUPnPSettings

## ui

GetRemoteSetting, SetRemoteSetting, Settings, Settings2, Settings3

## vlantagging

GetVLANTaggingSettings, GetVLANTaggingSettings2, SetVLANTaggingSettings, SetVLANTaggingSettings2

## vpn

GetTunneledUser, GetVPNGateway, GetVPNService, GetVPNUser, SetTunneledUser, SetVPNApply, SetVPNGateway, SetVPNService, SetVPNUser

## wirelessap

GetAirtimeFairnessSettings, GetDFSSettings, GetMLOSettings, GetRadioInfo, GetRadioInfo2, GetRadioInfo3, GetWPSServerSessionStatus, SetAirtimeFairnessSettings, SetDFSSettings, SetMLOSettings, SetRadioSettings, SetRadioSettings2, SetRadioSettings3

## wirelessscheduler

GetWirelessSchedulerSettings
