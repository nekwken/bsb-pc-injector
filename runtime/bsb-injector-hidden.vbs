' BSB injector launcher - starts the injector with no visible window.
' Used by the HKCU Run entry (see tools\Shortcuts.ps1). Window style 0 means the
' PowerShell console never flashes at logon.
Option Explicit

Dim fso, sh, root, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")

' this file lives in <project>\runtime\, so the project root is two levels up
root = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))

If Not fso.FileExists(root & "\start-injector.ps1") Then
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & root & "\start-injector.ps1"" -Background"

sh.Run cmd, 0, False
