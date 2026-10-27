' Silent launcher for the balance window (no console flash)
Option Explicit

Dim fso, sh, dir, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = dir & "\balance-window.ps1"

If Not fso.FileExists(ps1) Then
    MsgBox "balance-window.ps1 not found:" & vbCrLf & ps1, 16, "Balance Window"
    WScript.Quit 1
End If

cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """"

' 0 = hidden window, False = do not wait
sh.Run cmd, 0, False
