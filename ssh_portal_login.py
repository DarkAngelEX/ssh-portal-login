"""
校园网远程登录辅助脚本。

用法：
    python ssh_portal_login.py TARGET
    python ssh_portal_login.py user@a.b.c.d

可选参数：
    python ssh_portal_login.py user@a.b.c.d --port 1081
    python ssh_portal_login.py user@a.b.c.d --url https://10.248.98.2

登录原理：
    1. 脚本启动 SSH 动态端口转发：
       ssh -N -D 127.0.0.1:1080 user@a.b.c.d
    2. 本机的 127.0.0.1:1080 会变成一个 SOCKS5 代理入口。
    3. 浏览器只在临时 profile 中使用这个 SOCKS5 代理，不修改系统代理。
    4. 访问校园网登录页时，请求会经过 SSH 隧道从远程机器发出。
    5. 登录完成后回到终端按 Enter，脚本会停止 SSH 并删除临时 profile。

浏览器搜索顺序：
    修改 BROWSER_SEARCH_ORDER 即可调整优先级，例如：
    ["chrome", "edge", "firefox"]
"""

import argparse
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path


LOGIN_URL = "https://10.248.98.2"
SOCKS_PORT = 1080
PROFILE_NAME = ".campus-login-profile"
BROWSER_SEARCH_ORDER = ["chrome", "edge", "firefox"]


@dataclass
class Browser:
    name: str
    executable: str
    kind: str
    profile_key: str


def die(message: str, exit_code: int = 1) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(exit_code)


def require_ssh() -> str:
    ssh = shutil.which("ssh")
    if ssh:
        return ssh

    if os.name == "nt":
        hint = (
            "Windows 可在“设置 -> 系统 -> 可选功能”中安装 OpenSSH Client，"
            "或确认 ssh.exe 所在目录已加入 PATH。"
        )
    elif sys.platform == "darwin":
        hint = "macOS 通常自带 ssh；请确认 /usr/bin/ssh 存在，或检查 PATH。"
    else:
        hint = "Ubuntu/Debian 可运行：sudo apt install openssh-client"

    die(
        "未找到 ssh 命令，无法建立 SSH SOCKS5 隧道。\n"
        "请先安装 OpenSSH 客户端，并确保可以在终端中直接运行：ssh\n"
        f"{hint}"
    )


def browser_candidates(browser_key: str) -> list[tuple[str, str, Path | str]]:
    if os.name == "nt":
        windows_paths = {
            "edge": [
                (
                    "Microsoft Edge",
                    "chromium",
                    Path(root) / "Microsoft" / "Edge" / "Application" / "msedge.exe",
                )
                for root in (
                    os.environ.get("ProgramFiles"),
                    os.environ.get("ProgramFiles(x86)"),
                )
                if root
            ]
            + [("Microsoft Edge", "chromium", "msedge.exe")],
            "firefox": [
                (
                    "Firefox",
                    "firefox",
                    Path(root) / "Mozilla Firefox" / "firefox.exe",
                )
                for root in (
                    os.environ.get("ProgramFiles"),
                    os.environ.get("ProgramFiles(x86)"),
                )
                if root
            ]
            + [("Firefox", "firefox", "firefox.exe")],
            "chrome": [
                (
                    "Google Chrome",
                    "chromium",
                    Path(root) / "Google" / "Chrome" / "Application" / "chrome.exe",
                )
                for root in (
                    os.environ.get("ProgramFiles"),
                    os.environ.get("ProgramFiles(x86)"),
                    os.environ.get("LocalAppData"),
                )
                if root
            ]
            + [("Google Chrome", "chromium", "chrome.exe")],
        }
        return windows_paths.get(browser_key, [])

    if sys.platform == "darwin":
        macos_paths = {
            "edge": [
                (
                    "Microsoft Edge",
                    "chromium",
                    Path(
                        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
                    ),
                ),
                ("Microsoft Edge", "chromium", "msedge"),
            ],
            "firefox": [
                (
                    "Firefox",
                    "firefox",
                    Path("/Applications/Firefox.app/Contents/MacOS/firefox"),
                ),
                ("Firefox", "firefox", "firefox"),
            ],
            "chrome": [
                (
                    "Google Chrome",
                    "chromium",
                    Path(
                        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
                    ),
                ),
                ("Google Chrome", "chromium", "google-chrome"),
                ("Google Chrome", "chromium", "chrome"),
            ],
        }
        return macos_paths.get(browser_key, [])

    linux_paths = {
        "edge": [
            ("Microsoft Edge", "chromium", "microsoft-edge"),
            ("Microsoft Edge", "chromium", "microsoft-edge-stable"),
            ("Microsoft Edge", "chromium", "/usr/bin/microsoft-edge"),
            ("Microsoft Edge", "chromium", "/usr/bin/microsoft-edge-stable"),
            ("Microsoft Edge", "chromium", "/snap/bin/microsoft-edge"),
        ],
        "firefox": [
            ("Firefox", "firefox", "firefox"),
            ("Firefox", "firefox", "/usr/bin/firefox"),
            ("Firefox", "firefox", "/snap/bin/firefox"),
        ],
        "chrome": [
            ("Google Chrome", "chromium", "google-chrome"),
            ("Google Chrome", "chromium", "google-chrome-stable"),
            ("Google Chrome", "chromium", "chrome"),
            ("Google Chrome", "chromium", "chromium"),
            ("Google Chrome", "chromium", "chromium-browser"),
            ("Google Chrome", "chromium", "/usr/bin/google-chrome"),
            ("Google Chrome", "chromium", "/usr/bin/google-chrome-stable"),
            ("Chromium", "chromium", "/usr/bin/chromium"),
            ("Chromium", "chromium", "/usr/bin/chromium-browser"),
            ("Chromium", "chromium", "/snap/bin/chromium"),
        ],
    }
    return linux_paths.get(browser_key, [])


def find_browser() -> Browser:
    candidates: list[tuple[str, str, Path | str]] = []
    for browser_key in BROWSER_SEARCH_ORDER:
        candidates.extend(browser_candidates(browser_key))

    for name, kind, candidate in candidates:
        if isinstance(candidate, Path):
            if candidate.exists():
                return Browser(
                    name=name,
                    executable=str(candidate),
                    kind=kind,
                    profile_key=profile_key(name),
                )
            continue

        resolved = shutil.which(candidate)
        if resolved:
            return Browser(
                name=name,
                executable=resolved,
                kind=kind,
                profile_key=profile_key(name),
            )

    die("未找到 Edge、Firefox 或 Chrome，请确认至少安装其中一个浏览器。")


def profile_key(browser_name: str) -> str:
    return (
        browser_name.lower()
        .replace("microsoft ", "")
        .replace("google ", "")
        .replace(" ", "-")
    )


def profile_dir_for(script_dir: Path, browser: Browser) -> Path:
    return script_dir / f"{PROFILE_NAME}-{browser.profile_key}"


def remove_profile(profile_dir: Path) -> bool:
    if not profile_dir.exists():
        return True

    for _ in range(10):
        try:
            shutil.rmtree(profile_dir)
            return True
        except OSError:
            time.sleep(0.5)

    print(f"未能删除浏览器 profile，可能仍被浏览器占用：{profile_dir}")
    return False


def prepare_profile(profile_dir: Path, browser: Browser, socks_port: int) -> None:
    if profile_dir.exists():
        if not remove_profile(profile_dir):
            die(f"临时浏览器 profile 仍存在，可能被浏览器占用：{profile_dir}")

    profile_dir.mkdir(parents=True, exist_ok=False)
    if browser.kind != "firefox":
        return

    user_js = "\n".join(
        [
            'user_pref("network.proxy.type", 1);',
            'user_pref("network.proxy.socks", "127.0.0.1");',
            f'user_pref("network.proxy.socks_port", {socks_port});',
            'user_pref("network.proxy.socks_version", 5);',
            'user_pref("network.proxy.socks_remote_dns", true);',
            'user_pref("network.proxy.no_proxies_on", "");',
            'user_pref("browser.shell.checkDefaultBrowser", false);',
            "",
        ]
    )
    (profile_dir / "user.js").write_text(user_js, encoding="ascii")


def browser_args(
    browser: Browser, profile_dir: Path, url: str, socks_port: int
) -> list[str]:
    if browser.kind == "firefox":
        return [
            browser.executable,
            "--no-remote",
            "--profile",
            str(profile_dir),
            url,
        ]

    return [
        browser.executable,
        f"--user-data-dir={profile_dir}",
        "--no-first-run",
        "--no-default-browser-check",
        f"--proxy-server=socks5://127.0.0.1:{socks_port}",
        url,
    ]


def is_port_open(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.5):
            return True
    except OSError:
        return False


def stop_process(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return

    print("正在停止 SSH 代理...")
    try:
        process.terminate()
        process.wait(timeout=5)
        return
    except (OSError, subprocess.TimeoutExpired):
        pass

    try:
        process.kill()
    except OSError:
        pass


def wait_for_browser_or_enter(browser_name: str, process: subprocess.Popen) -> None:
    print()
    print(f"{browser_name} 已启动。")
    time.sleep(2)

    if process.poll() is not None:
        print("浏览器启动进程已经退出，无法可靠自动检测窗口是否关闭。")
        input("完成登录后按 Enter：")
        return

    done = threading.Event()

    def wait_for_enter() -> None:
        input("完成登录后按 Enter，或直接关闭浏览器窗口：")
        done.set()

    thread = threading.Thread(target=wait_for_enter, daemon=True)
    thread.start()

    while process.poll() is None and not done.is_set():
        time.sleep(0.5)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="通过 SSH 动态端口转发打开校园网登录页。"
    )
    parser.add_argument(
        "ssh_target",
        help="SSH 目标，例如 TARGET 或 user@a.b.c.d",
    )
    parser.add_argument("--url", default=LOGIN_URL, help=f"登录页，默认 {LOGIN_URL}")
    parser.add_argument(
        "--port",
        type=int,
        default=SOCKS_PORT,
        help=f"本机 SOCKS5 端口，默认 {SOCKS_PORT}",
    )
    parser.add_argument(
        "--wait-seconds",
        type=int,
        default=180,
        help="等待 SSH 代理就绪的秒数，默认 180",
    )
    args = parser.parse_args()

    require_ssh()

    browser = find_browser()
    script_dir = Path(__file__).resolve().parent
    profile_dir = profile_dir_for(script_dir, browser)

    prepare_profile(profile_dir, browser, args.port)

    ssh_process = None
    try:
        print(f"正在启动 SSH SOCKS5 代理：127.0.0.1:{args.port}")
        print("如果 SSH 需要密码，请直接在此窗口输入。")
        ssh_process = subprocess.Popen(
            [
                "ssh",
                "-o",
                "ExitOnForwardFailure=yes",
                "-N",
                "-D",
                f"127.0.0.1:{args.port}",
                args.ssh_target,
            ]
        )

        deadline = time.monotonic() + args.wait_seconds
        while not is_port_open("127.0.0.1", args.port):
            if ssh_process.poll() is not None:
                die("SSH 代理启动失败。", ssh_process.returncode or 1)

            if time.monotonic() > deadline:
                die(
                    f"等待 SSH 代理超时。请确认 SSH 已登录，且端口 {args.port} 未被占用。"
                )

            time.sleep(0.5)

        print(f"正在启动 {browser.name} 专用代理窗口...")
        browser_process = subprocess.Popen(
            browser_args(browser, profile_dir, args.url, args.port)
        )
        wait_for_browser_or_enter(browser.name, browser_process)
        return 0
    finally:
        if ssh_process is not None:
            stop_process(ssh_process)
        time.sleep(1)
        remove_profile(profile_dir)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print()
        print("已取消。")
        raise SystemExit(130)
