# Specifications

Outlined here are the initial specifications for Betterlink, a native MacOS app written in Swift for controlling an Insta360 Link Webcam. 

The goal is to have near full feature-parity with the first-party Insta360 Link Controller app. A thorough investigation into the first-party app was conducted, with the results available in `investigation-findings.md`. 

## Functionality / Feature Requirements

A short list of what must be included:

- Viewfinder
  - A live viewfinder showing what the camera currently sees must be included, and should be the center of the UI design. 
- Record start/stop control
- Resolution/fps control
- Orientation control
- Static preset switcher/creator
- Speed control
- CI/CD pipelines (see Pacer)
- Update pipeline using Sparkle (see Pacer)

## UI / UX Guidelines

**This is a MacOS app and it should appear accordingly.** Use the most up-to-date UI guidelines and development practices as laid out by Apple. 

There should be a vertical sidebar on the left hand side of the UI with the following tabs (at a minimum-- more can be added):
- (Section Title: OVERVIEW)
  - Dashboard
- (Section Title: PRESETS)
  - Preset Menu
  - Preset Builder
- Settings

Outside of the guidance given above, additional UI inspiration can be drawn from the first-party Insta360 Link Controller app, and Pacer. 

## Prior art to reference

### Specific Features/Functionality
- Previous Insta360 Link controller project: ~/GitHub/insta360link-joystick-controller
- Insta360 Link Controller (first-party app): /Applications/Insta360 Link Controller.app

### CI/CD, Updates 
- Pacer GitHub repo: https://github.com/EricAndrechek/Pacer