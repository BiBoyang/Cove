# TASK: Browser row badge type tints

- Status: landed 2026-09-12 (build/test green, 253/253)；真机 Owner 过目通过
- Slug: badge-tints

## Goal
Fix grey-on-grey placeholder badges: folder/video glyphs were
tertiaryLabel-on-secondarySystemFill and blended into the warm dark
background (Owner report 2026-09-12); image rows with real thumbnails
were already fine.

## Changes
- `placeholderTint(for:)` static mapping on BrowserViewController
  (internal for tests), configure() uses it instead of the blanket
  tertiary.
- CoveStyle token family badgeTint{Folder,Video,Pdf,Comic,Image,Text,
  Other} = systemBlue/Purple/Red/Orange/Green/secondary/tertiary;
  registered in design/DESIGN-TOKENS.md §1.
- Grey tile (.secondarySystemFill) unchanged: small saturated symbol on
  the neutral tile keeps real thumbnails the loudest row element.
- Test: badgeTints mapping per type (ViewModelTests).

## DoD
1. build/test 全绿 ✅（253/253）
2. 真机：文件夹蓝、视频紫、PDF 红、漫画橙、图片占位绿（转瞬被真
   缩略图顶替）、文本略亮、其他不变；缩略图仍是行内最跳元素。
3. 零布局变化（tile、尺寸、间距均未动）。
