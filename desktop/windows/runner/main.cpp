#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <cstdio>
#include <vector>

#include "flutter_window.h"
#include "resource.h"
#include "utils.h"

namespace {

void TLog(const char* message) {
  // 公开分发版只输出到调试器，不在用户磁盘上写任何日志文件。
  OutputDebugStringA(message);
  OutputDebugStringA("\n");
}

// ---- 原生 Win32 托盘图标 + 右键菜单 ----
// nativeapi 的 TrayIcon 在本机 Windows 上只报告 visible=true，却不会真正
// 调用 Shell_NotifyIcon 把图标挂到任务栏，所以这里直接走 Win32 API。

constexpr wchar_t kTrayWindowClass[] = L"MyNotesTrayWindow";
constexpr UINT kTrayMessage = WM_APP + 1;
constexpr UINT kIdShow = 40001;
constexpr UINT kIdHide = 40002;
constexpr UINT kIdNew = 40003;
constexpr UINT kIdSearch = 40004;
constexpr UINT kIdSettings = 40005;
constexpr UINT kIdQuit = 40006;

HINSTANCE g_instance = nullptr;
HWND g_tray_hwnd = nullptr;
NOTIFYICONDATAW g_nid = {};

HWND FindMainWindow() {
  HWND hwnd = FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", nullptr);
  if (!hwnd) {
    hwnd = FindWindowW(nullptr, L"我的笔记");
  }
  return hwnd;
}

void ShowMainWindow() {
  HWND hwnd = FindMainWindow();
  if (!hwnd) return;
  ShowWindow(hwnd, SW_SHOW);
  ShowWindow(hwnd, SW_RESTORE);
  BringWindowToTop(hwnd);
  SetForegroundWindow(hwnd);
  SetFocus(hwnd);
}

void HideMainWindow() {
  HWND hwnd = FindMainWindow();
  if (hwnd) ShowWindow(hwnd, SW_HIDE);
}

// 向已获得焦点的应用窗口发送 Ctrl+<vk>，触发界面里的快捷键
void SendCtrlKey(WORD vk) {
  INPUT inputs[4] = {};
  inputs[0].type = INPUT_KEYBOARD;
  inputs[0].ki.wVk = VK_CONTROL;
  inputs[1].type = INPUT_KEYBOARD;
  inputs[1].ki.wVk = vk;
  inputs[2].type = INPUT_KEYBOARD;
  inputs[2].ki.wVk = vk;
  inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;
  inputs[3].type = INPUT_KEYBOARD;
  inputs[3].ki.wVk = VK_CONTROL;
  inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;
  SendInput(4, inputs, sizeof(INPUT));
}

void HandleTrayCommand(UINT id) {
  switch (id) {
    case kIdShow:
      ShowMainWindow();
      break;
    case kIdHide:
      HideMainWindow();
      break;
    case kIdNew:
      ShowMainWindow();
      Sleep(150);
      SendCtrlKey(static_cast<WORD>('N'));
      break;
    case kIdSearch:
      ShowMainWindow();
      Sleep(150);
      SendCtrlKey(static_cast<WORD>('F'));
      break;
    case kIdSettings:
      ShowMainWindow();
      Sleep(150);
      SendCtrlKey(VK_OEM_COMMA);
      break;
    case kIdQuit:
      // 直接销毁主窗口：绕过 Dart 层的「关闭最小化到托盘」拦截，
      // WM_DESTROY 会 PostQuitMessage(0)，让应用正常退出。
      Shell_NotifyIconW(NIM_DELETE, &g_nid);
      {
        HWND main_window = FindMainWindow();
        if (main_window) {
          DestroyWindow(main_window);
        } else {
          ExitProcess(0);
        }
      }
      break;
    default:
      break;
  }
}

void ShowTrayMenu(HWND hwnd) {
  POINT pt = {};
  GetCursorPos(&pt);
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING, kIdShow, L"显示窗口");
  AppendMenuW(menu, MF_STRING, kIdHide, L"隐藏窗口");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kIdNew, L"新建笔记");
  AppendMenuW(menu, MF_STRING, kIdSearch, L"搜索笔记");
  AppendMenuW(menu, MF_STRING, kIdSettings, L"设置");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kIdQuit, L"退出");
  SetForegroundWindow(hwnd);
  const int command = TrackPopupMenu(
      menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_NONOTIFY, pt.x, pt.y, 0,
      hwnd, nullptr);
  PostMessageW(hwnd, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command > 0) {
    HandleTrayCommand(static_cast<UINT>(command));
  }
}

LRESULT CALLBACK TrayWndProc(HWND hwnd, UINT message, WPARAM wparam,
                             LPARAM lparam) {
  if (message == kTrayMessage) {
    switch (LOWORD(lparam)) {
      case WM_RBUTTONUP:
      case WM_CONTEXTMENU:
        ShowTrayMenu(hwnd);
        return 0;
      case WM_LBUTTONUP:
      case WM_LBUTTONDBLCLK:
        ShowMainWindow();
        return 0;
      default:
        return 0;
    }
  }
  return DefWindowProcW(hwnd, message, wparam, lparam);
}

bool InitTray(HINSTANCE instance) {
  TLog("InitTray enter");
  g_instance = instance;
  WNDCLASSW wc = {};
  wc.lpfnWndProc = TrayWndProc;
  wc.hInstance = instance;
  wc.lpszClassName = kTrayWindowClass;
  if (!RegisterClassW(&wc)) {
    TLog("RegisterClassW FAILED");
    return false;
  }
  TLog("RegisterClassW ok");

  g_tray_hwnd = CreateWindowExW(0, kTrayWindowClass, L"MyNotesTray", 0, 0, 0,
                                0, 0, HWND_MESSAGE, nullptr, instance,
                                nullptr);
  if (!g_tray_hwnd) {
    TLog("CreateWindowExW FAILED");
    return false;
  }
  TLog("CreateWindowExW ok");

  g_nid.cbSize = sizeof(g_nid);
  g_nid.hWnd = g_tray_hwnd;
  g_nid.uID = 1;
  g_nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP | NIF_SHOWTIP;
  g_nid.uCallbackMessage = kTrayMessage;
  g_nid.hIcon = reinterpret_cast<HICON>(
      LoadImageW(instance, MAKEINTRESOURCEW(IDI_APP_ICON), IMAGE_ICON,
                 GetSystemMetrics(SM_CXSMICON),
                 GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  if (!g_nid.hIcon) {
    g_nid.hIcon = LoadIconW(instance, MAKEINTRESOURCEW(IDI_APP_ICON));
  }
  lstrcpynW(g_nid.szTip, L"我的笔记 · 右键打开菜单",
            ARRAYSIZE(g_nid.szTip));
  TLog(g_nid.hIcon ? "icon loaded" : "icon MISSING");

  Shell_NotifyIconW(NIM_DELETE, &g_nid);  // 清理上次异常退出残留
  if (!Shell_NotifyIconW(NIM_ADD, &g_nid)) {
    TLog("first NIM_ADD failed, retrying");
    Sleep(400);
    if (!Shell_NotifyIconW(NIM_ADD, &g_nid)) {
      TLog("second NIM_ADD FAILED");
      return false;
    }
  }
  TLog("NIM_ADD ok");
  g_nid.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &g_nid);
  return true;
}

void RemoveTray() {
  Shell_NotifyIconW(NIM_DELETE, &g_nid);
  if (g_tray_hwnd) DestroyWindow(g_tray_hwnd);
  UnregisterClassW(kTrayWindowClass, g_instance);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  TLog("wWinMain enter");

  flutter::DartProject project(L"data");
  // Skia/ANGLE(D3D11) 后端在这台 AMD 核显上拖拽窗口明显更顺滑
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);

  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"my_notes", origin, size)) {
    return EXIT_FAILURE;
  }
  TLog("window.Create ok");
  window.SetQuitOnClose(true);

  InitTray(instance);
  TLog("entering message loop");

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }
  TLog("message loop ended");

  RemoveTray();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
