# dmgbuild settings for the img_to_ig disk image. make_dmg.sh passes the paths with -D.
# Icon centers must match scripts/make_dmg_background.swift (520x300 window, y from the top).
app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}

format = "UDZO"
compression_level = 9
filesystem = "HFS+"

background = defines["background"]
window_rect = ((200, 150), (520, 300))
default_view = "icon-view"
show_toolbar = False
show_status_bar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
icon_locations = {"img_to_ig.app": (130, 138), "Applications": (390, 138)}
