# TOOLKIT

`fullparser.py` currently only works on binary blobs containing the `"LPMT"` FourCC
Universal format support coming later. Includes pain, sorrow, and too many layouts to care

## Supported Layouts (WIP)

- 3x3 + Pos + Scale  
- 3x4 Matrix  
- 4x4 Matrix  
- 4x4 Transposed  
- 4x4 Inverted  
- 4x4 + 1/2/4/16 byte pad  
- 3x4 + 1/2/8/12 byte pad  
- 1int / 2int / 3int + Matrix  
- Short / Byte aligned formats  
- Variable header + 12f / 16f / 10f  
- Pos + Quat + Scale  
- Quat + Pos + Scale  
- Scale + Pos + Quat  
- Euler Angles  
- Axis + Angle  
- Dual Quaternion  
- Compact Quaternion  
- Fixed Int Layouts (i16/i32 based)  
- Decomposed TRS (with pivot or offset)  
- Split Matrix  
- Packed Transform  
- Bitpacked (64-bit)  
- Morton Encoded  
- String-prefixed  
- Double Precision  
- Mixed Precision  
- Nested Structures  
- Other cursed formats from hell

## FourCC Dump Script

`FOURCC filename.asd` - run it from CMD
Scans file and prints all FourCC tags with their offset
