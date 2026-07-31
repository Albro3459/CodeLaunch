# CodeLaunch

Remote Control Agent Setup (Codex in Claude Code w/ [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and **Remote Control** w/ [T3 Code](https://github.com/pingdotgg/t3code/tree/main/apps/desktop) over HTTPS w/ [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) + [Cloudflare Access](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/))

Tested on an ARM Mac (macOS 26.x), working end to end from off-network devices, phone included. Exact versions in [TOOL-VERSIONS.md](TOOL-VERSIONS.md). Day-to-day start/stop in [QUICK-SETUP.md](QUICK-SETUP.md). Full build docs in [SETUP.md](SETUP.md).

Browsers connect through Cloudflare Access. The mobile app pairs over a trusted LAN or VPN with `T3_BIND=all`; see [SETUP.md](SETUP.md#4e-direct-lanvpn-pairing-required-for-the-mobile-app).

## Screenshots + Remote Control Demo

#### Claude and Codex Subscriptions

<p align="center">
  <img
    src="https://github.com/user-attachments/assets/dc435aa9-8e9d-401b-903a-ca2a54419341"
    alt="Claude and Codex subscriptions in T3 Code"
    width="453"
  />
</p>

#### T3 Code Remote Control

<table>
  <tr>
    <th align="center">Desktop</th>
    <th align="center">Mobile</th>
  </tr>
  <tr>
    <td align="center" valign="top">
      <img
        src="https://github.com/user-attachments/assets/f3b13d12-4650-4609-be0e-618bef6e66ed"
        alt="T3 Code in the Browser"
        width="650"
      />
    </td>
    <td align="center" valign="top">
      <img
        src="https://github.com/user-attachments/assets/590268ab-e354-4a6c-9214-0ae50869f120"
        alt="T3 Code on mobile"
        width="218"
      />
    </td>
  </tr>
</table>

#### Mobile Demo

<table align="center">
  <tr>
    <td align="center">
      <video
        src="https://github.com/user-attachments/assets/32ff7ce2-fc4a-4eee-9fe8-e6e83ab5655e"
        width="220"
        controls
      ></video>
    </td>
  </tr>
</table>
