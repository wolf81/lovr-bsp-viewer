# Quake 1 BSP viewer

This project is based on the [BSP Renderer by Lucas Fryzek](https://github.com/Hazematman/BSP-Renderer).

In order to get a map to render, add a `.pak` file to the root of the project. Right now the first map is loaded automatically, but the code can be modified to load any other map of course (see `pak.lua`). This viewer only support BSP version 29 (including Quake Shareware version). I believe this version can be downloaded from [archive.org](https://archive.org).

**PLEASE NOTE:** the code is not perfect - in some ways it's a bit quick and dirty. I attempted a re-write based on the [BSP Viewer from Daniel Quast](https://github.com/danqua/bsp-viewer), but I figured it'd be too much work and there's more interesting stuff for me to work on. However, perhaps it can be useful for some people, for me it was certainly education in the following ways:

- Learning how to read binary files using ffi with Lua.
- Getting an idea on how Quake stored data in PAK & BSP files.
- Loading data asynchronously using LÖVR threads.
- And just generally getting the stuff to render properly with LÖVR.

Some ideas on how to improve the code base would be:

1. Re-write based on the viewer from Daniel Quast, which in my opinion is a bit cleaner.
2. Add shaders for sky, water.
3. Add lightning effects (e.g. torches).
4. Implement BSP-based rendering - I think this will only render the stuff that's visible, which I believe is what Daniel Quast's project achieves.
