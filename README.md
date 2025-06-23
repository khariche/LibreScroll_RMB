# LibreScroll
Smooth inertial scrolling on Windows with any regular mouse.

### [Download Here](https://github.com/EsportToys/LibreScroll/releases)

https://github.com/EsportToys/LibreScroll/assets/98432183/c7fc05a5-6b10-4b91-9984-0d809a52b025


## Instructions
1. Run LibreScroll
2. Hold Mouse 3 and move your mouse, the cursor will stay in-place, mouse motion is instead converted to scroll momentum.
3. Release middle-mouse-button to halt scroll momentum and release the cursor.


To compile from source, run 
```
zig build-exe main.zig main.rc main.manifest --subsystem windows
```

## Options

![image](https://github.com/user-attachments/assets/00ea0369-4a97-49f5-99ca-1b8d97b2ad2b)

### Friction
The rate at which momentum decays.

(Units: deceleration per velocity, in s&#8315;&sup1;)

### X/Y-Sensitivity
The horizontal/vertical multiplier at which mouse movement is converted to scroll momentum. 

Set a negative sensitivity to use reversed-direction scrolling, or zero to disable that axis entirely.

(Units: scroll-velocity per mouse-displacement, in s&#8315;&sup1;)

### Minimum X/Y Step
The granularity at which to send scrolling inputs.

This is a workaround for some legacy apps that do not handle smooth scrolling increments correctly. 

A "standard" coarse scrollwheel step is 120, and the smallest step is 1.

### Flick Mode
When enabled, releasing middle-mouse-button will not stop the scrolling momentum. 

Press any button again (or move the actual wheel) to stop the momentum.

### ThinkPad Mode
When enabled, scrolling snaps to either horizontal or vertical, never both at the same time.

This emulates how scrolling works on ThinkPad TrackPoints.

### Pause/Unpause
Temporarily disable the utility if you need to use the unmodified behavior in another app.

This kills the worker thread, which can be restarted by clicking Unpause or Apply.

### Apply
After modifying the preference, click this to apply the configuration as displayed.

This kills and restarts the worker thread with the new configuration.

## Recommended Settings for ThinkPad users (replacing TPmiddle)

With your TrackPoint's middle button set to "middle click mode", the following configurations are recommended to emulate TPmiddle's direct scrolling:

![image](https://github.com/user-attachments/assets/6a0ee926-d331-4481-8f6e-a5f6f2a01c94)

```
Friction: 30
Y-Sensitivity: 90
X-Sensitivity: 90
Minimum X-Step: 10
Minimum Y-Step: 10
Flick Mode: No
ThinkPad Mode: Yes
```
