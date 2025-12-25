# Glytch Mesh Mod for the WiFi Pineapple Pager

The **Glytch Mesh Mod** adds low-power mesh messaging capabilities to the WiFi Pineapple Pager using a dedicated radio module and a custom install payload.

This mod is designed for resilient, decentralized communications between multiple Pager devices (or compatible nodes), making it ideal for mesh messaging on the go.

---

## 📦 What’s Included
   - Glytch Mesh Mod for WiFi Pineapple Pager
   - Hand-assembled, 3D printed enclosure
   - LoRa compatibility via the SX1262 chipset

---

## 🚀 Getting Started

Follow these steps to configure your Mesh Mod on the WiFi Pineapple Pager:

1. Ensure your Pager is **charged**, **powered on**, **connected to the internet** and running the **latest firmware**  
   - Firmware update guide:  
     https://docs.hak5.org/wifi-pineapple-pager/updating/software-updates/

2. Attach the **Glytch Mesh Mod** to your Pager’s **USB port**

3. Download the install payload from the following URL:
   [PAYLOAD LINK]

4. Move the payload to your Pager via preferred method (SCP, etc)

5. Navigate to the payload and run.

   **NOTE: THIS PROCESS WILL TAKE APPROXIMATELY 5 MINUTES, DO NOT INTERRUPT**
   
6. Once the payload has finished, the MeshtasticD service is now enabled and running in the background.

   You may now connect to the Pager's IP via the Meshtastic App on your mobile device (172.16.52.1 if connected to Pager via Management AP or USB C)

7. Set your Region and Username in the LoRa Settings section of the Meshtastic App
   
✅ **Your Mesh Mod is now configured.**

---

## 📡 Usage Notes

For best results:

- Your Pager and Mesh Mod should be oriented vertically, outdoors or near windows and away from metal and other electronics
- Initial discovery and communication with other nodes may take **several minutes**, and is dependent on local node activity configuration, and conditions
- Atmospheric conditions, buildings, and terrain may affect range and signal quality

---

## 🤝 Community & Support

For help, tips, and community discussion:

###	💬 Hak5 Community Forums:
https://community.hak5.org


⸻

Happy hacking!
