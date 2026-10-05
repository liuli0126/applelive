# Progress

## 2026-10-04 飞书版完整操作教程
- 已开始整理面向普通用户的完整教程，范围包括 Windows/OBS v0.2.5、手机独立 dylib 注入、RTMP/RTSP 使用、iOS 13.3 专用 rootful 安装、升级和故障排查。
- 已确认当前独立 dylib 不兼容 iOS 13.3；13.3 专用 deb 已放入 `交付文件/AppleLive-iOS13.3-unc0ver-rootful-v0.1.11.deb`。
- 已生成 `交付文件/AppleLive-多版本完整操作教程-飞书版.md` 和 `.docx`。DOCX 可重新解析，包含 320 个段落、50 个标题和 8 张表。
- 已核对教程中的 v0.2.5、RTMP/RTSP 地址、主线 LAN 限制、iOS 13.3 旧通道隔离以及三个交付文件 SHA-256；实际文件哈希全部一致。

## 2026-10-03 mobile panel simplification

- Removed the Preview button, removed Mute, forced standalone audio controls to Internal Audio only, removed the vertical scroll view and compacted all sections into one screen. The preview HTML/PNG now shows a single complete panel with Pause + Restore Camera and the time readout beside the timeline.
- Successful CI `37089891485` (commit `9b8874a`) passed and its verified dylib replaced `交付文件/AppleLive.dylib`; SHA256 `3CA99F68D7705BFB7539DC3FF15398143DD90779897F42179AAC4365ADD08604`. Delivery ZIP was refreshed and all bundled hashes match.
- Follow-up source commit `3b1f6fa` only improves playback row placement. CI `37090276595` was blocked before starting by GitHub account billing/spending limit, including one retry; the successful artifact remains the delivered phone file until CI billing is available.

## 2026-10-02 mandatory local video looping

- `586e9b1` / CI `37003673977`: removed the loop switch and runtime flag; Album/Files videos now always rewind at EOF with reopen fallback. Migration discards saved loop-off preferences. Repeated-loop, pause/seek/cancel/PCM, RTMP/RTSP and both architecture checks passed. This revision has not been tested on a physical phone.
- Refreshed the existing HTML preview and PNG in place; verified the rendered playback section no longer shows the switch.
- Replaced `交付文件/AppleLive.dylib` with SHA256 `22371DFB3223118814B058E95490F815C45F5E66112ED405C2F9E81DBC66B94E`. Repository and installed OBS download copies match. Updated the six bundled phone artifacts in the delivery ZIP; each matches the CI artifact, ZIP SHA256 `5BA92EB6ED96C40B454C983FB833A6CB4EC0F2FBB123CDB07B0D2A5BAE5BCF50`.

## 2026-10-02 mobile cyber UI delivery

- 2026-10-02 手机改版完成：`286bcef` / CI `37000248401` 移除单文件插件旧 LAN 电脑连接入口，保留检测 RTMP/RTSP 与 USB；旧来源设置自动迁移。黑红切角面板、圆形透明悬浮图标及圆形触摸范围；迁移/路由、循环/PCM、RTMP/RTSP 与 arm64/arm64e 构建验证全部通过，未声称真机验证。
- 已交付唯一手机文件 `交付文件/AppleLive.dylib`（10,629,136 字节，SHA256 `18900DBBDD23425D0FB2884D778B5620C853F07ACBF39E8FB87E4B3387CC4347`）。旧 `AppleLive-192.168.1.45-8765.dylib` 移入 `.build/obsolete-delivery-20261002` 可恢复，不再显示在交付目录。
- 新 dylib、对应重链接材料和许可证同步至仓库/已安装 OBS 的 `phone-plugin`，交付 Windows ZIP 只更新这六个手机附件并逐一验证哈希。ZIP 新 SHA256 `DD0B4B32818C8BD84B0A53FB997D4B1511A4E54EA35B02BA3AC1C46954AED798`。OBS 设置及可执行文件未改动。
- GitHub CLI 下载停滞，停止该下载进程后改为并行 HTTP Range 下载；完整 artifact SHA256 与 GitHub digest 一致，dylib 与 CI SHA256 文件一致，实际二进制包含新圆形/主题类且不含旧连接电脑/电脑地址标签。

## 2026-10-02 delivery-folder cleanup

- User requested a single unambiguous package and authorized stopping idle AppleLive processes and deleting obsolete deliveries. Stopped four verified `AppleLiveDock.exe` processes; no OBS process was running.
- Direct deletion was rejected by execution policy. Moved seven obsolete delivery entries to `.build/obsolete-delivery-20261002` without overwriting, and renamed the sole validated archive to `交付文件/AppleLive-OBS-最新版.zip`. Its SHA256 remains `54ECDBBB4CAB4576DB90F5F7D0CB2DE6BC428B602FE02302922BAF8CD5E667E8`. The old files were not permanently deleted.

## 2026-10-02 address display correction

- Confirmed screenshot refers only to the WebSocket address card in the OBS dock. Work in progress: reverse `b4676db`, remove the card, then verify and package without changing RTMP/RTSP behavior.
- Reverted `b4676db` without a commit, then removed `address_box` and its two JS references; changed only stale help text. Node syntax, protocol, dock (14), phone download (2), and transport (3) tests passed.
- Default-port MediaMTX smoke test timed out because the still-running user delivery has no RTSP listener; leaving that process untouched and validating on separate ports.
- An isolated-port PowerShell smoke command was rejected before execution by policy. No server process was changed; CI on a clean runner will cover the existing RTMP/RTSP test.
- Rebuilt both Windows executables, restored the `0a7ecca` iOS 14+ dylib (SHA256 `F92309D7FA1FF90CB77194648A66709D12EF4A8E5ADE1F0D8F214B5BE32D55E1`), and wrote a newly named delivery ZIP without touching running installations. ZIP checks passed for no WebSocket card, RTMP card present, RTSP/RTMP enabled, and phone bytes matching the verified build.
- Committed correction as `44cf0e2`. First GitHub push failed with connection reset; checking connectivity before a compatible retry.
- HTTPS Git push failed twice, but SSH authentication worked. Pushed `44cf0e2` through the SSH URL without changing the configured remote; waiting for GitHub CI.
- GitHub run `36994322792` succeeded. Its Windows log confirms RTMP H.264/AAC publish and RTSP pull, plus H.264 tee/audible AAC; iOS 14+ injector and the other triggered workflows succeeded too.
- The custom local OBS directory was updated only in `dock/index.html` and `dock/app.js` after backing up those two files to `.build/obs-dock-backup-20261002-ui-only`. Existing LAN/high/computer-audio settings and RTSP config remained unchanged. The active 18765 endpoint still serves the old delivery-directory page, so its visible reload is pending a normal user restart; no running process was terminated.
- Optional CI artifact download stalled and was canceled. Final local delivery remains `交付文件/AppleLive-OBS-Windows-仅移除WebSocket地址.zip`, already verified against the requested UI, both protocols, and the restored phone-library hash.

## 2026-10-01 final MediaMTX and internal-audio delivery

- cd13b4b passed injector, full OBS, legacy rootful and rootless CI. Fixed C++ runtime linkage in the relink kit and Windows wrapper-process cleanup in the stream tests; integration tests use separate paths. No phone apps or installed debs were modified.
- Internal audio now feeds independent capture-delegate and AudioUnit rings. Removed the delegate-priority bypass that could leave original microphone data in the other input path. PCM layouts and underflow silence pass host tests; live-app microphone replacement still needs device confirmation.
- Delivered artifacts/AppleLive-192.168.1.45-8765.dylib, AppleLive-Phone.zip and AppleLive-OBS-Windows.zip. Phone SHA256: 80e35457dc3b455d7c008f0feb2d227f5269a7732f56d7cc0e20dc5f5ff43c4d. HTTP download and both bundles contain identical phone bytes. Licenses, source and relink materials accompany the bundles.
- The OBS bundle combines the tested 6fde1ff PC binaries with cd13b4b phone materials and current README/USB helper; PC Python/Lua/web source is identical in these builds. Updated only the installed AppleLive directory, with a backup at artifacts/obs-plugin-backup-media-20261001-183905. Retained LAN, high, 1080x1920/30fps/8Mbps and the user's currently enabled computer audio.
- Real OBS output probes confirm H.264/1080x1920 and AAC/48kHz/stereo through MediaMTX; RTSP decode and legacy WebSocket video/PCM reception pass. Playwright validates stream-address copy, QR, phone download and layout at 280/560px. These are PC checks, not phone latency or app compatibility measurements.
- Standalone USB remains independent of SSH. The legacy helper exits before launching Python/SSH when no matching private key exists; the no-key SingleAttempt branch was executed successfully. Packaging now checks required Python modules before freezing.
- Final phone guide is artifacts/ios-injector-cd13b4b/README-手机操作.txt. iOS15.6 app injection, live-app internal audio, preview/photo, physical USB, TikTok and additional iOS versions remain pending user device tests. The original iOS13.3 phone was left unchanged.

## 2026-10-01 match tested reference feature scope

- User supplied Vacm_afasds_v10(2).dylib and confirmed it is tested and works well; explicitly requests matching its full functionality. Static comparison saved in artifacts/DYLIB_COMPARISON.md. Reference is4884752bytes, arm64/iOS14.0,22 system dependencies, built-in FFmpeg libavformat60.16.100 and Objective-C runtime hooks. Our current434720-byte dylib is arm64+modernarm64e/iOS15.0 and OBS WebSocket only.
- Confirmed reference interfaces for local image/video selection, loop, RTMP/RTSP/HLS-capable FFmpeg, audio decode/resample, network preview, AVCaptureVideoPreviewLayer overlay and JPEG still-photo interception. It has no external Substrate/ElleKit dependency. USB implementation and actual latency cannot be inferred from this phone file.
- Implementing equivalent capabilities with public FFmpeg source and our existing engine. New source/media/preview modules are standalone-only so the original iOS13.3 tested deb installation is preserved. Requested reference UI screenshots asynchronously while work continues.

## 2026-10-01 standalone dylib distribution

- Standalone commit61828ac compiled successfully (injector36824607865). No Substrate/ElleKit linkage; distinct Objective-C class names and app-local stream status. Actual app injection remains untested.
- Adding a filename address profile, app-local connection notifications, signed-byte-preserving downloads and an OBS QR download dialog. OBS Windows CI will include the matching dylib from a reusable workflow in the same run. QR dependency is installed only in CI, not on the user's machine.
- Retain original iOS13.3 phone and existing Vacm dylib on the iOS15.6 phone. Independent injection needs our deb filter disabled before verification. USB still requires the existing SSH setup; audio and broader OS compatibility remain unverified.
- Reviewed standalone controls and removed their Darwin-notification dependency as well: app-local rotation/mirror/audio control delivery and app-owned defaults. Standalone initialization no longer imports legacy global enable flags.
- Latest sourcebcbb96c passed all CI builds: standalone36827733454, OBS36827733643, rootless36827733461, rootful36827733500. Same-run standalone artifact434720bytes SHA2565ad87f29784a8fbfd22170b30f0387bf163df95a34a3cbe8c503f063e3b6fe92 verified locally and uploaded as AppleLive-192.168.1.45-8765.dylib into the existing injector Documents. Phone copy hash matches.
- Disabled only our own /var/jb/usr/lib/TweakInject/AppleLive.plist by renaming it .disabled-injector-test, restarted Aweme/mediaserverd and opened wiki.qaq.TrollFools. OBS connections dropped from2 to1 as expected. User asked to import the file normally and report the target preview; no claim of standalone success yet.
- Git API commit publication hit one transient error; retry with stderr inspection succeeded. Large OBS artifact download via gh stalled; using a fresh signed download URL and stripping API authorization on the cross-host redirect. An extraction attempted before the first download finished failed harmlessly; no installed files changed yet.
- Fresh artifact download completed using bounded parallel HTTP ranges and matched GitHub's artifact digest. Retired the superseded sequential downloader. Updated only installed AppleLive files after confirming OBS was neither streaming nor recording. Backup: artifacts/obs-plugin-backup-bcbb96c. OBS stayed open; original high/LAN/1080x1920/30fps/8Mbps/audio-off settings retained and transmission resumed with the original phone connected.
- Actual installed dock passed Playwright at280px/560px with working modal, Escape dismissal and downloaded filename. OpenCV decoded the actual qrcode/Pillow PNG to http://192.168.1.45:8765/phone-plugin; LAN and browser downloads exactly match the signed434720-byte library. Screenshot found an author display rule overriding a hidden label; added a global hidden rule and zero heading letter spacing. Independent phone import/preview still awaits user.
- Current portable ZIP artifacts/AppleLive-OBS-Windows.zip includes the tested final HTML/CSS and matching signed library. The already-open OBS dock still holds the old page; right-click/F5 did not refresh it. Subsequent UI input guards refused to act while another app owned foreground, so no further clicks were sent. New panel is usable at http://127.0.0.1:18765/; existing OBS dock requires reload/reopen. OBS remains22256 with normal LAN capture and the original phone connected.

## 2026-10-01 iOS15.6 Dopamine LAN test

- User clarified the desired product delivery is a dylib imported by their existing virtual-camera injector, because setting up many phones through SSH/Sileo is cumbersome. This steers the main delivery toward standalone app injection; the Dopamine package remains a separate testing route.
- Identified installed injector: wiki.qaq.TrollFools, display name Virtual Camera Injector (Chinese), version9.999/build42, TrollFools.app. It declares Mach-O document import and UIFileSharingEnabled. Existing Douyin already contains Frameworks/Vacm_afasds_v10(1).dylib; preserve it and assess possible conflicts before changing app injection.
- Rootless0.1.13 and rootful0.1.13 CI succeeded (36822936606/36822936580); downloaded rootless0.1.13. Preparing independent ios-injector library target with system Objective-C method replacement instead of Substrate linkage, distinct ObjC class names, local app stream status, and app-owned connection persistence. GitHub workflow will verify both architectures and reject external framework dependencies.
- Identified actual new phone as iPhone12,1 (iPhone11), iOS15.6 build19G71, modern Dopamine rootless/procursus at /var/jb. OpenSSH9.7p1-1 enabled ports22/2222. The public default mobile password failed once; user set a new mobile password in Dopamine and entered it through a local masked GUI, never in chat or files.
- Installed ElleKit1.2 and AppleLive0.1.12 with dpkg after verified transfer hashes; both report install ok installed. APT simulation crashed and its automatic install refused an unauthenticated ElleKit index. Downloaded the official HTTPS ellekit.space/pool/ellekit_1.2_iphoneos-arm64.deb and verified SHA256e21dc91bdc1be193dc915daecfff45256239b4fe583a36861e662ab1f43906dc before direct installation; no allow-unauthenticated flag used.
- Created per-device key/pin applelive-ssh-f6d0b440ebedafe9. Rootless SSH account homes are /var/jb/var/mobile and /var/jb/var/root, unlike the original phone. Mobile and root key authentication now both verified; removed only this new public key line from the initially used system-home authorized_keys files. Password console closed and password discarded.
- Used officially verified jbctl reboot_userspace; SpringBoard and mediaserverd restarted, SSH key access recovered. Douyin bundle com.ss.iphone.ugc.Aweme, version39.9.0. No fresh Aweme/Camera/mediaserverd crash reports found. No TikTok app was detected under the expected executable names; audio remains off.
- OBS restarted PID22256, sender1032, LAN/high1080x1920/30fps/8Mbps/audio-off. Current receiver is only original192.168.1.53, not the new phone. New mediaserverd preferences contain AppleLive.Connection.v1 host0.0.0.0 despite the supplied legacy address plist; this confirms tweak load but a failed initial address import.
- Preparing0.1.13 with AppleLiveSetup, reusing ALConnection parse/publish code to configure LAN through Darwin notifications and have mediaserverd persist its own preferences. Awaiting fresh CI and device validation; user was asked to inspect the new phone's Douyin preview without starting a broadcast.
- Latest settings photo e2aaccaa12c930729673cacc9ab0a7b0.jpg clearly shows Refresh Jailbreak Apps, Reinstall Package Managers, enabled tweak injection/iDownload/JIT. This matches the newer menu and supersedes the earlier old-UI assumption. Selection photo bc1bb2eef72a9f542e47b4fdd9283126.jpg shows Sileo checked and Continue, which returns to settings after installation.
- Guided user to the visible Refresh Jailbreak Apps action; user confirms Sileo can now be found and opened. Asked them to install OpenSSH Server in Sileo and reconfirm the phone's current Wi-Fi IP because192.168.1.28 ports22/2222/1337 time out and usbmux still lists no devices. Awaiting these prerequisites before device-specific authentication/install.
- New phone photo329fe63c12aa8fcadb5b6d37b6e1f6b6.jpg showed the older Dopamine UI with button Jailbreak and disabled respring/userspace-reboot controls, correcting the earlier user-reported active state. Guided the user to complete jailbreak; user subsequently confirmed the actual button now reads Jailbroken, but Sileo remains absent from the home screen after selection.
- Verified official Dopamine1.1.11 SettingsView.swift and PackageManagerSelectionView.swift: Reinstall Package Managers is inside the bootstrapped/jailbroken section; selecting Sileo must be followed by pressing Reinstall. This old UI has no Refresh Jailbreak Apps action. Next step is actual reinstall then Spotlight search before SSH setup.
- Rootless0.1.12 archive checks passed:50,356bytes, SHA2562ae9dc27c3688eafa3be2b7be89519dc54dc8d29621832d92920969c47effe0f; executable postinst, var/jb installation paths, arm64 plus modern arm64e, iOS15.0 minimum and rootless rpaths. Evidence: artifacts/ios-rootless-v0.1.12/AppleLive-rootless-deb/package-inspection.json. The initial inspection assertion assumed a leading slash in tar member names; normalized the archive path and rechecked successfully.
- User cannot find Reinstall Package Managers in their actual Dopamine settings. Need main screen with version and settings screenshot to identify this build/menu before further device instructions. No phone installation/authentication performed. Current PC address remains192.168.1.45; no OBS/AppleLive process is running.
- 0.1.12 commit b4d4518e59a4d6ab8ad406504c3079f3c6829637 built successfully: rootless run36817649689 and iOS13 rootful run36817649708. Downloaded the rootless artifact to artifacts/ios-rootless-v0.1.12; installation on the new phone is still pending.
- User reports Dopamine's actual main button reads Jailbroken. Official Dopamine2.x source/localization confirms Settings -> Reinstall Package Managers -> Sileo. Guided the user through this because Sileo is currently absent; awaiting result before SSH setup.
- On resuming,192.168.1.28 ports22/2222 time out and the local dock18765 refuses connections. These are fresh observations; the previous OBS/sender process state must not be assumed current.
- User introduced an iOS15.6 test device, confirmed Dopamine jailbreak is active and that this phone connects via LAN at192.168.1.28. USB enumeration correctly shows no devices; do not infer this is the original iOS13.3 phone, whose existing receiver remains at192.168.1.53.
- Both SSH22 and2222 on192.168.1.28 actively refuse connections. Asked user to install/enable OpenSSH Server in Sileo; no authentication attempts were made.
- Inspected rootless0.1.11 artifact: only dylib/filter, no legacy preferences or postinst. Existing initialization treated missing enabled/audioEnabled values as false, preventing fresh installs from connecting. Preparing0.1.12 with defaults when keys are absent (preserving explicit opt-outs), rootless postinst, minimum firmware15.0, and signature validation for the copyNextSampleBuffer hook.
- User mentioned TrollStore virtual-camera injectors, but confirmed this actual test phone has completed Dopamine jailbreak. The separate injector tool's identity was not provided; use the confirmed jailbreak environment for this test.

## 2026-10-01 USB recovery, phone buttons and video stalls

- Final user feedback: phone Disconnect/Connect works and picture is smooth. Sustained LAN/high output measurement after warmup:602frames over20.0227seconds,30.016fps (PC-side measurement, not end-to-end latency). Current modeLAN, high1080x1920/30fps/8Mbps, audio off, two phone receiver processes.
- USB supervisor syntax check and duplicate-supervisor mutex behavior passed. No-device enumeration now gives the correct no-phone error and retries (rather than invalid UDID). Installed Lua, USB script and sender hashes match source/build. The cable is currently unplugged; physical unplug/replug auto-recovery has not been fully device-tested. Supervisor PID37060 follows OBS15664; current in-memory Lua has older launch arguments but reuses this supervisor, and next script load reads the updated ObsPid launch.

- USB sender was active but local2222 forwarder had disappeared. A stale pre-key SSH process41848 survived, so process-only reuse skipped reconstruction. Retired that verified stale process and restored tunnel; user confirmed OBS picture returned.
- Added a per-route USB supervisor mutex, checks for real forwarding listener and established SSH TCP transport, retries, actual forwarder readiness waiting, no hidden password prompt, USB-only device filtering, and OBS lifetime tracking. Current phone was unplugged during testing and PC selection changed to LAN; preserved LAN/high/audio-off and installed the supervisor changes.
- Diagnosed video stalls: Python AnnexBParser saturated a core at about99% while FFmpeg capture dropped frames continuously. Old parser repeatedly scanned large incomplete NALs byte by byte. Native byte search plus incremental cursor reduced a960040-byte/4096-chunk fixture from6.0349s to0.0022s; chunk-boundary and large-NAL regression tests passed. Installed rebuilt sender. Actual sender CPU sampled0%; LAN/high output measured288frames in10.008s (~28.8fps including startup).
- Added phone connection toggle in0.1.11, globally shared pause through the connection notification, real disconnect/retry of receive clients, frame/audio clearing and immediate original-camera fallback. Legacy notifications migrate to unpaused auto mode. Both iOS CI builds passed (rootful36815887666/rootless36815887772); Windows36815887703 also passed.
- Installed rootful0.1.11 over pinned Wi-Fi SSH (56,016bytes, SHA25620c503574339a74989777db474b18996c247b68b411094debd582e93305a2304), restarted test apps and opened Douyin. User confirmation of button interaction and perceived smoothness pending; USB unplug/replug regression requires the cable to be reattached.

## 2026-10-01 install inside existing OBS

- User clarified they want installation inside the OBS folder. Installed the existing package to `D:/OBS定制款/OBS定制款/obs studio/data/obs-plugins/AppleLive`; native Qt rewrite was not pursued.
- Verified OBS streaming and recording inactive before shutdown. After confirmation, OBS saved layout/scenes, unloaded scripts and cleared scenes, but hung in obs-websocket unload; ended only that already-shutting-down process. Configuration backup: `artifacts/obs-install-backup-20261001`. Migrated AppleLive script registration only; retained the user's mixer script, scene content, high/LAN/audio-off settings and dock layout.
- Added UTF-8 filesystem calls and wide-character process creation to Lua. Local actual LuaJIT/OBS DLL fixture verified Chinese path read/write/rename/remove and successful sender launch with an intentionally missing test camera.
- Restarted OBS (PID15664); new-folder dock helper loaded automatically and existing panel restored. Fixed newly exposed asynchronous virtualcam startup, reloaded the updated script and clicked the real dock start button from camera-off state. Sender running (PID27816), phone connected over LAN, 1080x1920/30fps/8Mbps, audio off. No phone package change or local development-tool download.

## 2026-10-01 per-app floating controls

- User clarified that Douyin already displays the correct orientation while stock Camera is upside down, then requested a floating control panel inside target apps. The unshipped global flip was replaced by per-app defaults (Camera EXIF 8, Douyin/TikTok EXIF 6) plus saved rotation adjustments.
- Implemented a UIKit floating button and panel with pass-through background touches, drag positioning, safe-area clamping, collapse, enable, quarter-turn rotation, mirror, fit/fill and PC audio controls. Settings and position use the host app's preferences; Darwin notification state carries the active app's settings to mediaserverd without cross-sandbox file writes.
- Added camera-service status updates for fresh video/audio and USB/LAN, plus live rendering settings. The microphone setting gates the existing app audio replacement path; actual PC-audio capture/injection is still unverified.
- Applying ui-ux-pro-max's native safe-area, 44pt touch-target and control-spacing guidance. Awaiting compilation, notification IPC and on-device UI tests for 0.1.6.
- Rootful CI run 36806477292 (commit c35350d) passed compilation and the legacy ABI gate. Downloaded 0.1.6 (47,796 bytes, SHA-256 `c0e664db7591abed8533018706f505c80c9acef068653c8fba2b5d674bde1dac`), verified the phone copy and installed with dpkg. Restarted Camera/Aweme and issued `uiopen com.ss.iphone.ugc.Aweme` to load the new app code.
- mediaserverd and Aweme continue decoding 720x1280 over USB after update. The bounded syslog capture did not capture a floating-controls-ready or control-change message; do not yet claim visual appearance or IPC adjustments are verified. User has been asked to check the button, rotate left and reset in Douyin's camera preview; awaiting that result. Phone screenshot service remains unavailable, so no automatic screenshot validation was performed.

## 2026-10-01 camera output path repair

- User confirms the Camera preview still shows the physical camera on 0.1.4. USB clients increased to two, confirming separate camera/service connections; no recent Camera/mediaserverd crash reports were found in the mobile CrashReporter folder.
- Current implementation only attempts `BWNodeOutput copyNextSampleBuffer`. Published Celestial runtime headers instead expose `emitSampleBuffer:`. Preparing 0.1.5 to verify the runtime method signature and hook that push path when the copy accessor is absent.
- New push hook paints the decoded stream into the original video pixel buffer using Core Image, preserving dimensions, timing, format and camera metadata. Unsupported pixel formats and non-video samples pass through. Added sampled decode/render logs and explicit hook availability logs to verify actual behavior on the phone.
- Awaiting CI compilation and phone tests; this change does not yet establish successful preview replacement.
- CI run 36805192850 succeeded for 0.1.5 (commit cb4f08f). Installed via SSH after read-back SHA-256 validation (`381319a4c040d50eed32b7b464b056cb1cb31b936d24bd5293f8336571b44e1f`). Device confirmed `BW hooks class=1 copy=0 emit=1 signature=v24@0:8^{opaqueCMSampleBuffer=}16`, 720x1280 decoding and continuous rendering into 2304x1296 NV12 camera buffers. User confirms OBS is visible, but upside down.
- Correcting the portrait transform from EXIF 6 to EXIF 8 in 0.1.6; awaiting the new build and visual check. Stock Camera replacement is now confirmed, but Douyin/TikTok, PC audio, other orientations, LAN and latency still need tests.
- Standard git push was unreliable while the GitHub API worked. Used `artifacts/git-api-push.py` to publish exact matching local blob/tree/commit objects and fast-forward main with identity checks; no history rewrite. Screenshot service was unavailable without a developer image; no dependencies were downloaded for screenshots.

## 2026-10-01 USB connection and iOS 13 ABI repair

- OpenSSH 8.4-2 is running. With the user's explicit default-password instruction, logged in as mobile and verified `com.applelive.tweak` 0.1.3, installed library/filter, and USB/LAN configuration.
- Created a dedicated Ed25519 key outside the repository at `%USERPROFILE%/.ssh/applelive-<UDID>` and appended its public key to the phone's mobile authorized_keys. Existing keys were preserved. USB scripts now use that key when available; PowerShell syntax check passed.
- Left usbmux forwarding on local 2222 (PID 32844) and SSH reverse forwarding to phone 127.0.0.1:8765 (PID 41268) running. Verified an HTTP 101 WebSocket upgrade through the phone's loopback listener. This diagnostic connection is not proof of tweak camera reception. Sender still reports zero persistent clients.
- User reports stock Camera still shows its own camera. Confirmed the installed arm64e slice uses subtype 0x80000002, but iOS 13 Camera and mediaserverd use legacy subtype 2. Theos arm64e deployment documentation confirms modern clang cannot target the legacy ABI merely by lowering the deployment version. Douyin 39.9.0 uses arm64; its app fallback needs separate testing.
- Preparing rootful 0.1.4 with legacy clang 10 and iPhoneOS13.7 SDK in GitHub Actions, plus a package ABI verification gate. No compiler downloads to the user's PC.
- Phone locked during diagnostic relaunch, so a request to unlock and keep Camera open is pending. `uiopen com.apple.camera` is the correct command; this device's uiopen does not accept `--bundleid`. Some phone command line utilities (log/netstat/lsof) are absent; use the paired USB syslog service and SSH channels instead.
- GitHub rootful run 36804057641 (commit 19fd41d) succeeded with the legacy compiler and ABI gate. Downloaded rootful 0.1.4 (24,070 bytes, SHA-256 `9487da40f4d30ed168b733e176c3937aed035268d2f098fac6d59bb6d51dcbca`), copied via authenticated SSH/SFTP, verified read-back hash, and installed directly with dpkg. The user's confirmed default password also authenticated root for this installation; no password was stored.
- Device log now confirms AppleLive.dylib injection into mediaserverd, hooks initialization, and connection startup. The sender shows one persistent USB client after installation (diagnostic handshake clients are closed). Camera image replacement, audio, Douyin/TikTok and end-to-end latency are still unverified until the user unlocks and checks the preview.
- Replaced the temporary manually started tunnel with the updated packaged USB script (parent PowerShell PID 26448), verified its key authentication and a new HTTP 101 handshake, and rebuilt the Windows ZIP. OBS sender and USB script remain running for the phone preview test.

## 2026-10-01 phone installation and connection setup

- Copied `AppleLive-0.1.3.deb` to AFC `/`, corresponding to Filza `/var/mobile/Media/`, and verified the read-back SHA-256 matches the local iOS 13 rootful package. User reported installation complete; installed files and tweak injection have not yet been independently verified.
- USB still detects the same iPhone 11 / iOS 13.3. A fresh usbmux connection to phone TCP port 22 was refused, so the OpenSSH service required by the current USB tunnel is not yet available.
- Used the running OBS local WebSocket interface to start its virtual camera. OBS log confirms Program output started. Started the existing AppleLiveSender executable with HD Camera, NVENC, 720x1280/30 fps and 5 Mbps. Status is running on port 8765, with zero phone/USB connections. PC audio is not enabled.
- Sender is intentionally left running for the user's phone connection test; stop through the OBS AppleLive panel. Existing Windows firewall profiles are disabled; no firewall settings were changed. Awaiting phone OpenSSH setup and an actual camera/live-app image test.

## 2026-09-30 low-latency pass

- Simplified the OBS panel to quality, connection mode, audio toggle, and start/stop; technical settings are hidden until Advanced is enabled. USB mode launches the tunnel window.
- Added iOS periodic preferred-USB probe so an active LAN connection can switch to USB without restarting the live app. Awaiting iOS 13 build and device test for this change.
- Converted incoming 48 kHz stereo PC audio to the camera callback's channel count and sample rate, with a bounded 200 ms ring. Device audio output remains to be tested.
- Corrected the OBS panel to show Stopped after a stale status file from an earlier session; the customized OBS already has AppleLive.lua registered from the repository path.
- Found the customized OBS virtual camera registered as `HD Camera` at 1080x1920/30 fps; verified FFmpeg captures it. Its inactive state displays the OBS placeholder.
- Added NVENC auto selection, bounded 5 Mbps VBR, a 15-frame GOP at 30 fps, 20 ms audio reads, a 24-packet client queue, and IDR recovery after overload. Kept aspect ratio while scaling to 720x1280.
- Desktop WebSocket smoke test received SPS/PPS plus about 30 fps, with first IDR after 0.34 s. This is not a phone or live-app latency measurement.
- Added USB reverse SSH tunnel script and iOS USB-first/LAN-fallback addresses. Phone USB detection works; its SSH port 22 is closed, so USB streaming remains unverified.

## 2026-09-30
- 检查工作区，确认为空目录。
- 查询公开 LordVCAM 资料，确认是越狱虚拟摄像头 tweak，不是普通 App。
- 读取公开协议线索：WebSocket 8765、H.264 NAL、float32 PCM、mediaserverd 注入。
- 建立任务计划，下一步实现桌面发送端和协议测试。
- 完成桌面发送端、H.264 Annex-B 分帧、float32 PCM 打包、LAN WebSocket 服务和 USB 转发脚本。
- 完成 iOS tweak 的 WebSocket 接收、VideoToolbox 解码、视频帧缓存、音频 ring buffer 和相机 delegate/BWNodeOutput 注入入口。
- 修复 Annex-B 小块读取缓存 bug和音频交错帧计数 bug；Python 协议自测与 WebSocket 握手自测通过。
- FFmpeg 实际桌面采集冒烟测试通过；带 VB-CABLE 音频时同时收到 `fram` 和 `audi` 消息。
- 修复 Windows 结束进程树残留和音频 10ms 队列挤掉视频的问题；确认 AppleLive 的 FFmpeg 子进程无残留。
- 当前机器无 Theos/iPhoneOS SDK，未生成 iOS deb；README 已写明构建命令和验证边界。
- 最终检查通过：Python 协议测试、AST 检查、PowerShell 语法检查；无 AppleLive 测试 FFmpeg 或临时目录残留。
- 新增 `DOWNLOADS.md`，列出 iPhone 越狱依赖、Theos 构建机、Windows 采集端和 USB 反向隧道前置条件，并要求用户提供目标设备参数。
- GitHub Actions rootless 构建成功，产物为 `com.applelive.tweak_0.1.0_iphoneos-arm64.deb`；当前包用于 LAN 第一阶段验证，USB 监听器仍待实现。
- 收到新需求：将电脑端做成 OBS 脚本插件。当前机器未检测到 OBS，计划使用 OBS 内置 Lua 脚本控制打包后的发送器，并采集 OBS Virtual Camera。
- OBS Lua 脚本和 AppleLiveSender.exe 已完成；dshow 摄像头收帧、状态文件、停止清理和 Lua 语法检查通过。正在安装 OBS 进行面板实测。
- `winget` 下载的 OBS 官方安装器缓存 SHA256 与官方值不符，未运行该文件；实际 OBS 面板暂未能在本机验证。Lua 运行时模拟的启动/停止按钮测试通过。
- 为 OBS 脚本增加启动/停止状态保护和心跳超时提示；发送器状态文件加入更新时间。协议自测、Lua 语法检查和本地 ZIP 构建通过，压缩包包含 Lua、exe 与说明。等待 GitHub Actions Windows 构建结果。
- 本地 ZIP 中的无控制台发送器用不存在的视频设备实测：写入 `error` 状态和 FFmpeg 日志后退出，无残留进程；异常不再触发 Windows 错误弹窗。
- GitHub Actions Windows 工作流成功（run 36677356994），已上传 `AppleLive-OBS-Windows` ZIP；本机尚无可运行的 OBS，真实脚本面板与目标 iPhone 的抖音/TikTok 尚未实测。
- 用户照片确认目标手机为 iPhone 11 / iOS 13.3 / unc0ver + Cydia + Substitute。新增 iOS 13.0 最低部署版本的 rootful 构建工作流、rootful 控制文件和测试 App 注入过滤器；需在 CI 生成包并在该设备上验证。
- GitHub Actions rootful 构建成功（run 36684920099）；下载并检查 `com.applelive.tweak_0.1.0_iphoneos-arm.deb`，控制信息为 iphoneos-arm、`mobilesubstrate | com.ex.substitute`，dylib/plist 位于 rootful 的 `/Library/MobileSubstrate/DynamicLibraries/`。同次触发的 rootless 构建也成功，真实手机相机和直播 App 效果未验证。

## 2026-10-01 OBS dock and unified transport controls

- Reference UI supplied: album, file, network entry labeled detection, mirror, mute, internal audio, rotation, restore camera. User confirmed internal audio must replace the microphone entirely. Their desktop server is the existing MediaMTX 1.18.1 at E:/服务器/服务器/mediamtx_v1.18.1_windows_amd64, not SRS.
- Added standalone FFmpeg media player, source picker panel, preview/photo hooks and PCM injection supporting planar/interleaved formats with silence on underflow. Host playback and PCM tests plus a generated H.264/AAC fixture are now CI gates. Implementation and builds are still in progress; no new phone result claimed.
- PC MediaMTX integration passed RTMP H.264/AAC publication and RTSP audio/video decoding. USB socket integration verified fragmented handshake, packet ordering, keyframe recovery and cleanup. Fixed an existing queue pump bug which spawned duplicate send tasks on every polling tick. Both existing deb workflows still pass. iOS media libraries build for arm64, arm64e and macOS host; host PCM sample construction test exposed a CoreMedia buffer issue under investigation.
- Added and ran the production encoder tee test on this PC with both x264 and NVIDIA NVENC: verified raw Annex-B SPS/PPS/IDR plus non-silent AAC decoded through MediaMTX. The test exposed the missing global header configuration for FLV, now fixed while explicitly repeating extradata for legacy receivers. Device CI strict unused-symbol guards are being fixed; artifacts are not yet updated.
- Full arm64 device build now passes. PCM injection and underflow silence tests passed after switching to an owned ready audio CMBlockBuffer and the audio-specific sample constructor. Playback tests exposed that seeking while paused stopped at the preceding keyframe; fixed decoding through the requested frame before pausing again. Added low-buffer network input and repeatable MediaMTX RTMP fixture publication.

- Implemented and installed OBS browser dock, Lua bridge, packaged helper, settings/controls, and live status. UI start/stop and saving mode are verified in running OBS. Removed only the duplicate old AppleLive Lua registration, preserving its files.
- Initial phone connection UI 0.1.7 installed; user successfully connected via LAN (phone 192.168.1.53, PC 192.168.1.45). User correctly identified conflicting PC selected USB versus actual LAN status, and requested one unambiguous selection.
- Final design: PC selects USB or LAN and enforces that transport at WebSocket handshake; USB binds loopback, LAN rejects loopback before upgrade. Phone 0.1.9 auto-follows and shows the actual transport, with only LAN computer-address editing. Rootful and rootless builds pass; 0.1.9 installed over USB, SHA256 5ff6ab37901a8e652f19b4f4c8efe6404ceefd1835c8f66dd3f9e085278d5fe1.
- Fixed sandboxed connection persistence via mediaserverd NSUserDefaults and iOS15 deprecation for legacy keyboard focus fallback. Dock protocol/control/transport tests pass. Final real-device PC-only USB/LAN switch verification is running; audio, TikTok, and latency remain unverified.

- Final device transport test passed: switched solely through the PC control API from LAN to USB and back to LAN; the phone followed each change. USB listener refused the PC LAN address; LAN server rejected USB tunnel handshake with HTTP403. Evidence: artifacts/dock-transport-verification.json. Current user-selected settings are LAN and high (1080x1920/30fps/8Mbps), audio off; preserved. OBS scene JSON confirms settings persistence. Local ZIP bytes match current Lua, README and web assets.

- Windows CI run 36810659851 passed protocol, HTTP dock, and transport handshake tests and produced the OBS ZIP. iOS0.1.9 device log confirmed 1080x1920 decoding/rendering on LAN. Log also exposed a stale frame in the app fallback after a transport change; preparing 0.1.10 with 750ms frame expiry, cleared media timestamps, and 5-second stalled-stream reconnect. This avoids a frozen app buffer replacing current system camera frames.

- Final stability repairs shipped: iOS0.1.10 rootful/rootless CI both passed (36811369644 / 36811369526). Installed rootful package directly, 55,400 bytes, SHA256 ab81a5b3a7137aa35eac43d69f6558d85341ca5b4bcbed811023389a7063c849.
- Reproduced Windows status-file sharing failure with a real reader handle; status writes now retry and skip transient failures rather than terminating video. Stopped status is published after the WebSocket listener closes.
- Dock helper previously could exit on a single transient bridge-file read gap. It now caches the recent heartbeat and watches the actual OBS process handle. LuaJIT native PID call verified; running helper launched with OBS PID23600.
- Final Windows CI36811840389 passed and rebuilt the distributable. Local ZIP is updated; LAN high-quality transmission restarted with two receivers and audio off. User needs only stop/select/start on PC; phone no longer presents a competing transport selector.
# OBS streaming controls (2026-10-03)
- User clarified the new phone workflow uses RTMP/RTSP only. OBS now publishes directly to `live/applelive` through MediaMTX; phone uses RTSP pull. No virtual camera or old sender is exposed in the new panel.
- OBS Lua cannot schedule a Lua function with `obs_queue_task` in this build; polling frontend APIs from its graphics-thread timer also crashed. Replaced those controls with local OBS WebSocket 5 requests, including automatic authentication from the local OBS configuration. Lua now only launches the dock helper.
- The installed custom OBS accepted `SetStreamServiceSettings`, `StartStream`, and `StopStream`. While streaming, FFprobe read `1080x1920` H.264 video and AAC audio from `rtsp://192.168.1.45:8554/live/applelive`; OBS is left stopped with the local service configured.
- Dock HTTP tests (6), WebSocket authentication test (1), MediaMTX RTMP/RTSP integration, JavaScript syntax, Lua syntax and `git diff --check` passed. The first ZIP had duplicate normalized paths because `Compress-Archive -Force` updated an existing archive; build now creates a fresh archive, and the final ZIP extracted cleanly into a separate directory. The extracted helper connected to OBS on port 18766, then was stopped.
- Final delivery ZIP, extracted package and installed OBS phone download all contain the current `AppleLive.dylib` SHA256 `3D119368F5709E39A5852BAB275A14337FD58E537DACA2158B499FB868BB3FEE`.
## 2026-10-05 USB direct mode restoration
- Resumed the AppleLive project after pausing the separate iOS capture work.
- Audited current OBS dock, installer, desktop sender, usbmux transport and standalone injector.
- Confirmed the direct USB transport is implemented but disconnected from the current OBS and phone UI/package.
- Started phase 28 to reconnect, package and verify the no-SSH USB path.
- Chose a localhost RTMP bridge for OBS-to-sender input so USB carries the same OBS video and mixed audio without virtual camera or external audio drivers.

## 2026-10-05 portable OBS packaging
- Added `scripts/build-portable-obs.ps1`, which copies an operator-provided OBS root, embeds AppleLive under `data/obs-plugins/AppleLive`, creates portable mode, pre-registers the dock/WebSocket config, and writes `AppleLive-Launcher.cmd`.
- Extended `obs-plugin/install_or_update.ps1` with `-Embedded` mode so the updater can configure an already-embedded package without copying over itself. It now recognizes renamed custom launchers by name pattern.
- First real build from `D:\OBS定制款\OBS定制款\obs studio` completed as `artifacts/AppleLive-OBS-Portable.zip` (SHA256 `08F3154A770247D0F529E07A40E297736B194BDAA52E6052E6AC24CD62DFD834`), but inspection found runtime log markers copied from the development package; the builder cleanup list was expanded and the archive needs one clean rebuild.
- Clean portable rebuild completed from `D:\OBS定制款\OBS定制款\obs studio`.
- Final archive: `artifacts/AppleLive-OBS-Portable.zip`, 385+ MB compressed package, SHA256 `7D9959307081835BD601BFEAB13772BE1BF02A4E25584961292A4B07FC15A321`.
- Extract verification confirms `AppleLive-Launcher.cmd`, portable marker, embedded dock/sender/MediaMTX/phone dylib, pre-registered AppleLive dock (`127.0.0.1:18765`) and enabled OBS WebSocket. The embedded phone SHA256 file now matches the dylib (`DFBC7C138FD25F6F34B3DD1367D38002DEFC54C24D6A27E98FE16361A6CD1F63`). No runtime log/flag files are present.
- The package is delivery-ready for the supplied OBS base. USB stability still differs from the reference because the loopback bridge has an FFmpeg/Python hop; matching the reference native OBS output/relay requires a separate native plugin phase.

## 2026-10-05 reference alignment and USB bridge

- Static PE/import audit confirmed the reference `vcamtang-obs-usb.dll` is a native OBS encoded output: it imports OBS output/encoder APIs, Winsock listen/accept/send, and contains keyframe gating, bounded queue, and relay-stall messages. Its relay speaks the Apple usbmux plist protocol and uses port 28765 for Douyin.
- The reference driver setup repairs Apple Mobile Device Support/usbmux binding and service state before installing optional camera/audio drivers. Those drivers are setup dependencies; the reference USB media hot path does not read a virtual camera.
- AppleLive USB now configures OBS to publish to `rtmp://127.0.0.1:1935/live/applelive`, starts the bundled MediaMTX server, and feeds the loopback stream to the existing usbmux sender. Virtual camera and VB-Cable discovery were removed from the packaged USB path; USB startup probe was shortened to 1 second.
- Tests: 17 desktop protocol/dock/transport tests pass, then the full 21-test desktop suite passes. JavaScript syntax and `git diff --check` pass.
- Rebuilt `artifacts/AppleLive-OBS-Portable.zip` from `D:\OBS定制款\OBS定制款\obs studio`. SHA-256: `D1163DC7783EDE32C96D854BD45614CEAC7A6A395C7FF0158AFE92D22`. Extraction contains the embedded dock/sender/MediaMTX/dylib and no runtime log or status files. The remaining difference from the reference is the FFmpeg/Python hop; native output + native relay is Phase 30's final parity work.
