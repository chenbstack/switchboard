# dmgbuild 配置：由 make-dmg.sh 调用，变量 app / bg / icon 通过 -D 传入
import os
app = defines["app"]
application = os.path.basename(app)

format = "UDZO"
size = None
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["bg"]
icon = defines["icon"]

window_rect = ((200, 120), (660, 432))  # 高度含约 32pt 标题栏，内容区 660x400 与背景图一致
icon_size = 112
text_size = 13
icon_locations = {application: (180, 190), "Applications": (480, 190)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
arrange_by = None
