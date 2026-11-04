# Logo prompt

Paste this into ChatGPT (image generation). It asks for plain, full-bleed artwork on purpose: the
`make-icon.sh --mask` script adds the macOS rounded-square shape, margin and shadow for you.

## Prompt

> Design the artwork for a macOS app icon for an app called **SpaceKeeper** — a utility that gives every
> macOS desktop ("Space") its own windows and lets you send windows between desktops.
>
> **Concept:** a stack of three overlapping app windows fanned slightly like separate desktops, the front one
> bright and sharp, the two behind it softer and more transparent, suggesting "separate rooms for your work".
> Optional small touch: a tiny pin or keyhole detail on the front window to suggest "keeping" things in place.
>
> **Style:** modern, minimal, premium, Apple "Big Sur / Tahoe" icon language — soft depth, gentle gradient,
> subtle inner highlight, smooth rounded shapes. A deep indigo-to-azure blue gradient background
> (around #5B4FE8 to #1190F5) with white / frosted-glass windows. One clear focal glyph, centered, readable
> even at 16×16 px.
>
> **Hard requirements:**
> - Square 1:1 image, 1024×1024, **full-bleed** — the background gradient fills the entire square.
> - **No rounded corners, no border, no drop shadow, no transparent margin** (I will add the macOS shape myself).
> - Keep all important elements inside the central 70% of the image.
> - **No text, no letters, no logos of other companies, no UI screenshots, no photorealism.**
> - Flat/gentle 3D look, not a busy illustration.

## Variations to try (append to the prompt)

- "Make the three windows form a subtle letter **S** shape." (only if the result stays clean)
- "Use a warm sunset gradient (coral to violet) instead of blue."
- "Show only two windows and a small padlock-free pin, even more minimal."
- "Dark graphite background with a single glowing blue window in front."

## Turning the image into the app icon

1. Save the image you like as `logo.png` (square, ideally 1024×1024 or larger).
2. From the project folder run:

   ```bash
   ./scripts/make-icon.sh --mask logo.png
   ./scripts/build.sh --install
   ```

   This writes `Resources/AppIcon-source.png` and `Resources/AppIcon.icns` and rebuilds the app with your icon.
3. If your image is already a finished icon (rounded, with transparent margin), skip the mask:
   `./scripts/make-icon.sh logo.png`.
4. Commit `Resources/AppIcon.icns` and `Resources/AppIcon-source.png` so everyone who builds the app gets your icon.
