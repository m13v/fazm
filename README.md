# Fazm — Your AI Computer Agent

The fastest AI computer agent. Controls your browser, writes code, handles documents, operates Google Apps, and learns your workflow — all from your voice.

**Free to start. Fully open source. Fully local.**

🌐 [fazm.ai](https://fazm.ai)

## Demos

### Twitter Automation
Fazm browses Twitter, engages with posts, and manages your social presence hands-free.

[![Twitter Automation](https://img.youtube.com/vi/_tI4LUO131c/maxresdefault.jpg)](https://www.youtube.com/watch?v=_tI4LUO131c)

### Smart Connections
Automatically find and connect with the right people across platforms.

[![Smart Connections](https://img.youtube.com/vi/0vr2lolrNXo/maxresdefault.jpg)](https://www.youtube.com/watch?v=0vr2lolrNXo)

### CRM Management
Keep your CRM up to date without lifting a finger — Fazm handles data entry and updates.

[![CRM Management](https://img.youtube.com/vi/WuMTpSBzojE/maxresdefault.jpg)](https://www.youtube.com/watch?v=WuMTpSBzojE)

### Visual Tasks
Fazm understands images and visual context to complete complex workflows.

[![Visual Tasks](https://img.youtube.com/vi/sZ-64dAbOIg/maxresdefault.jpg)](https://www.youtube.com/watch?v=sZ-64dAbOIg)

## Structure

```
Desktop/        Swift/SwiftUI macOS app (SPM package)
acp-bridge/     ACP bridge for Claude integration (TypeScript)
dmg-assets/     DMG installer resources
```

## Development

Requires macOS 14.0+, Xcode, and code signing with an Apple Developer ID.

```bash
# Run (builds Swift app and launches)
./run.sh

# Run with clean slate (resets onboarding, permissions, UserDefaults)
./reset-and-run.sh
```

## License

MIT
