import json
import os
from pathlib import Path
from typing import TYPE_CHECKING, Any, cast

import vapoursynth as vs

# Menu category > option name > possible choice > SVPFlow options
ConfigMap = dict[str, dict[str, dict[str, dict[str, Any]]]]


def deep_merge(source: dict[Any, Any], destination: dict[Any, Any]) -> None:
    for key, value in source.items():
        if isinstance(value, dict):
            node = destination.setdefault(key, {})
            deep_merge(cast("dict[Any, Any]", value), node)
        else:
            destination[key] = value


def snake_case(name: str) -> str:
    return name.replace(" ", "_").lower()


if TYPE_CHECKING:
    video_in = vs.VideoClip()
    video_in_dw = 1920
    video_in_dh = 1080
    container_fps = 24
    display_res = (1920, 1080)
    display_fps = 60

basedir = Path(__file__).resolve().parent

if os.name == "nt":
    menu_json = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "svp_menu.json"
    config_json = Path(os.environ["LOCALAPPDATA"]) / "Temp" / "svp_config.json"
else:
    menu_json = Path(os.environ["TMPDIR"] or "/tmp") / "svp_menu.json"
    config_json = Path(os.environ["TMPDIR"] or "/tmp") / "svp_config.json"

win_w, win_h = display_res
# win_w, win_h = user_data.split("/")
# win_w, win_h = int(win_w), int(win_h)

user_cfg: dict[str, str] = json.loads(config_json.read_text())
cfg2svparams: ConfigMap = json.loads((basedir / "map.json").read_text())

svparams: dict[str, dict[str, Any]] = {}
for _section, opts in cfg2svparams.items():  # noqa: PERF102
    for name, choices in opts.items():
        if (choice := user_cfg.get(snake_case(name))):
            deep_merge(choices[choice], svparams)

if user_cfg["fill_with_light"] == "Disabled":
    svparams["smoothfps"]["light"] = {"lights": 2, "length": 0, "aspect": 1.7778}

src_fps = cast("float", container_fps)
if src_fps <= 0.1 or round(src_fps, 2) == 23.81:
    src_fps = 23.976

base = user_cfg["multiplicand"]
times = user_cfg["multiplier"]
to_fps = src_fps
screen_fps = cast("float", display_fps) or 60

if base == "Video FPS":
    if str(times).startswith("Auto"):
        factor = 1
        while src_fps * factor < screen_fps - 9:
            factor += 1

        to_fps = src_fps * factor
        if times == "Auto (respect vsync)":
            to_fps = min(to_fps, screen_fps)
    else:
        to_fps = src_fps * float(times)
elif base == "Screen FPS":
    if str(times).startswith("Auto"):
        times = "1"
    to_fps = screen_fps * float(times)
else:
    if str(times).startswith("Auto"):
        times = "1"
    to_fps = float(base.split(" FPS")[0]) * float(times)

svparams["smoothfps"].setdefault("rate", {}).update({
    "num": to_fps * 10_000,
    "den": 10_000,
    "abs": True,
})
svparams["smoothfps"].setdefault("light", {})["aspect"] = win_w / (win_h or 1)
# TODO: light settings, NVOF, RIFE, 8/10bit options

deep_merge({
    "super": json.loads(user_cfg["json_super"] or "{}"),
    "analyse": json.loads(user_cfg["json_analyse"] or "{}"),
    "smoothfps": json.loads(user_cfg["json_smoothfps"] or "{}"),
}, svparams)

# [(categoryName, [(optionName, [value, ...]), ...]), ...]
menu_entries: list[tuple[str, list[tuple[str, list[str]]]]] = []
for section, stuff in cfg2svparams.items():
    if section == "Overrides":
        continue
    opts = [(opt, list(choices)) for opt, choices in stuff.items()]
    menu_entries.append((section, opts))

menu_json.write_text(json.dumps(menu_entries, indent=4))

core = vs.core
core.num_threads = ((os.cpu_count() or 2) * 2) - 1
core.max_cache_size = 8192

thread_opt = user_cfg["processing_threads"]
if thread_opt != "Do not change":
    core.num_threads += int(thread_opt)

if not hasattr(core, "svp1"):
    core.std.LoadPlugin(basedir / "third_party" / "svpflow1_vs.dll")
if not hasattr(core, "svp2"):
    core.std.LoadPlugin(basedir / "third_party" / "svpflow2_vs.dll")

if user_cfg["duplicate_frames_removal"] == "Remove every other frame":
    clip = video_in.std.SelectEvery(video_in, 2, 0).std.Trim(length=5000000)
else:
    clip = video_in.std.Trim(length=5000000)

highbit = clip.format.bits_per_sample >= 10
if highbit and video_in_dw * video_in_dh * src_fps <= 3840 * 2160 * 30:
    input_um = clip.resize.Point(format=vs.YUV420P10, dither_type="random")
    input_m = input_um
    input_m8 = input_m.resize.Point(format=vs.YUV420P8)
else:  # no 10 bit decoding
    input_um = clip.resize.Point(format=vs.YUV420P8, dither_type="random")
    input_m = input_um
    input_m8 = input_m


sup = core.svp1.Super(input_m8, json.dumps(svparams["super"]))
vectors = core.svp1.Analyse(
    sup["clip"], sup["data"], input_m8, json.dumps(svparams["analyse"]),
)
smooth = core.svp2.SmoothFps(
    input_m, sup["clip"], sup["data"], vectors["clip"], vectors["data"],
    json.dumps(svparams["smoothfps"]), src=input_um, fps=src_fps,
)

if user_cfg["fill_with_light"] == "Disabled":
    delta_w = smooth.width - clip.width
    delta_h = smooth.height - clip.height
    if delta_w or delta_h:
        left = delta_w // 2
        right = delta_w - left
        top = delta_h // 2
        bottom = delta_h - top
        smooth = core.std.Crop(
            smooth, left=left, right=right, top=top, bottom=bottom,
        )

assume = core.std.AssumeFPS(
    smooth, fpsnum=smooth.fps_num, fpsden=smooth.fps_den,
)
assume.text.ClipInfo()
assume.set_output()
