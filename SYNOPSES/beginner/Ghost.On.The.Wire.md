# Ghost on the Wire

## Overview
Build a Layer 2 attack and defense toolkit using Python and Scapy that combines MAC address spoofing, ARP cache poisoning, ARP spoof detection, and a real-time network trust map into a single tool. This project teaches the fundamentals of Layer 2 networking, how man-in-the-middle attacks work at the data link layer, and how to detect and defend against them—covering both the red team and blue team perspectives in one project.

## Step-by-Step Instructions

1. **Understand Layer 2 networking fundamentals** by studying how MAC addresses identify devices on a local network, how ARP (Address Resolution Protocol) maps IP addresses to MAC addresses, and why ARP has no authentication mechanism—any device can claim to be any IP address. Research the ARP cache, gratuitous ARP packets, and how switches forward frames based on MAC addresses.

2. **Implement MAC address spoofing** that changes your network interface's MAC address programmatically. Include vendor OUI (Organizationally Unique Identifier) lookup so you can impersonate specific device manufacturers, random MAC generation for anonymity, and MAC address restoration to the original hardware address. Handle interface down/up cycling required for MAC changes on Linux.

3. **Build ARP cache poisoning functionality** using Scapy to craft and send forged ARP reply packets that associate your MAC address with another device's IP address—the core of a man-in-the-middle attack at Layer 2. Implement continuous ARP poisoning (targets' ARP caches expire and need re-poisoning), bidirectional poisoning for full MITM position, and IP forwarding to maintain network connectivity for the victim.

4. **Create real-time ARP spoof detection** that monitors the network for signs of ARP poisoning: duplicate IP-to-MAC mappings, rapid ARP reply floods, MAC addresses that change unexpectedly, and gratuitous ARP packets from suspicious sources. Build a baseline of known device-to-MAC associations and alert when deviations occur.

5. **Develop a Layer 2 trust map** that continuously scans the local network and maintains a real-time map of all devices: their IP addresses, MAC addresses, vendor identification (via OUI), first-seen and last-seen timestamps, and a trust score based on behavioral consistency. Flag devices exhibiting spoofing behavior or whose MAC addresses don't match expected vendors.

6. **Build a TUI (terminal user interface) dashboard** using a library like Rich or Textual that displays the network trust map in real-time, shows active ARP poisoning attempts (both yours and detected external ones), highlights suspicious devices, and provides a command interface for switching between offensive and defensive modes.

7. **Add network reconnaissance capabilities** including passive host discovery (listening for ARP broadcasts), active ARP scanning to enumerate all devices on a subnet, OS fingerprinting based on ARP timing characteristics, and switch/router detection via MAC address table analysis.

8. **Create documentation covering both offensive and defensive perspectives** with legal warnings about unauthorized network attacks, explanation of how enterprise NAC (Network Access Control) prevents these attacks, detection techniques used by commercial IDS/IPS systems, and comparison to tools like arpspoof, ettercap, and Bettercap.

## Key Concepts to Learn
- ARP protocol mechanics and vulnerabilities
- MAC address structure and OUI vendor identification
- Man-in-the-middle attacks at Layer 2
- Scapy packet crafting and network interaction
- ARP spoof detection techniques
- Network trust modeling
- TUI dashboard development

## Deliverables
- MAC address spoofer with vendor OUI lookup
- ARP cache poisoner with bidirectional MITM
- Real-time ARP spoof detection engine
- Layer 2 network trust map with scoring
- TUI dashboard with offensive/defensive modes
- Passive and active network reconnaissance
