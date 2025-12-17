# Glytch GPS Mod for WiFi Pineapple Pager

Designed by **Glytch** in collaboration with **Hak5**, the **Glytch GPS Mod for the WiFi Pineapple Pager** adds precise GNSS location data to your Pager for wardriving and location-aware recon.

This GPS Mod features a **Quectel LC86 GNSS chipset** with **multi-constellation support**, is **3D printed and hand-assembled**, and may show small variations typical of handcrafted hardware.

👉 **Product page:**  
https://shop.hak5.org/collections/glytchtech/products/glytch-gps-mod-for-pager

---

## 📦 What’s Included

- Glytch GPS Mod for WiFi Pineapple Pager  
- Hand-assembled, 3D printed enclosure  
- GNSS support via the Quectel LC86 series chipset

---

## 🚀 Getting Started

Follow these steps to configure your GPS Mod on the WiFi Pineapple Pager:

1. Ensure your Pager is **charged**, **powered on**, and running the **latest firmware**  
   - Firmware update guide:  
     https://docs.hak5.org/wifi-pineapple-pager/updating/software-updates/

2. Attach the **Glytch GPS Mod** to your Pager’s **USB port**

3. On the Pager, navigate to:  
   **Settings → GPS**

4. Select **Baud Rate** and configure:
   - **LC86L GPS Mod** → `9600`
   - **LC86G GPS Mod** → `115200`

5. Select **Serial Device** and choose:  
   `ttyUSB0`

6. Select **Restart GPSd**

✅ **Your GPS Mod is now configured.**

---

## 📡 Usage Notes

For best results:

- Your GPS Mod must have a **clear, unobstructed view of the sky**
- Initial satellite acquisition may take **several minutes**
- **Atmospheric conditions**, buildings, and terrain may affect lock time and signal quality

---

## 🚗 Wardriving with Wigle

The Glytch GPS Mod enables location-aware wardriving and Wigle-compatible logging.

### Start a Wardriving Session

1. From the Pager dashboard, navigate to **Recon**
2. Press **`A`** to open the **settings menu**
3. Toggle **Wigle Mode** **ON**

### End a Wardriving Session

1. Return to the **Recon** settings menu
2. Toggle **Wigle Mode** **OFF**

📁 Your Wigle-compatible file will be saved to:

/root/loot/Wigle

## 🔗 Learn more about Wigle:  
https://wigle.net

WiGLE (Wireless Geographic Logging Engine) is a website for collecting information about the different wireless hotspots around the world. Users can register on the website and upload hotspot data like GPS coordinates, SSID, MAC address and the encryption type used on the hotspots discovered. In addition, cell tower data is uploaded and displayed

---

## 🛠 Troubleshooting

If you run into issues, the following commands can help diagnose GPS behavior.

### Restart GPSd
```sh
service gpsd restart
```

### Check GPSd Status
```
service gpsd status
```

### View Realtime GPS Stats

```
gpspipe -w -x 10 | fgrep TPV | jq .
```

This will output live JSON telemetry from the GPS Mod, including fix status and coordinates.

## 🤝 Community & Support

For help, tips, and community discussion:

###	💬 Hak5 Community Forums:
https://community.hak5.org


⸻

Happy hacking!
