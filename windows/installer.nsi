Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
Name "PC Remote"
OutFile "${PACKAGE_DIR}/PCRemote-Windows-x64-Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\PCRemote"
InstallDirRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "InstallLocation"
RequestExecutionLevel user
SetCompressor /SOLID lzma
VIProductVersion "${PRODUCT_VERSION}"
VIAddVersionKey "ProductName" "PC Remote"
VIAddVersionKey "FileDescription" "PC Remote Windows x64 Setup"
VIAddVersionKey "FileVersion" "${PRODUCT_VERSION}"
VIAddVersionKey "LegalCopyright" "PC Remote contributors"

!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\PCRemote.exe"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_ICONSTOP "This installer requires 64-bit Windows."
    Abort
  ${EndIf}
FunctionEnd

Section "PC Remote"
  SetOutPath "$INSTDIR"
  File "${PAYLOAD_DIR}/PCRemote.exe"
  File "${PAYLOAD_DIR}/AppleTVRemote.exe"
  File "${PAYLOAD_DIR}/README-Windows.md"
  File "${PAYLOAD_DIR}/Third-party-notices.txt"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\PC Remote"
  CreateShortcut "$SMPROGRAMS\PC Remote\PC Remote.lnk" "$INSTDIR\PCRemote.exe"
  CreateShortcut "$SMPROGRAMS\PC Remote\Apple TV Remote.lnk" "$INSTDIR\AppleTVRemote.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "DisplayName" "PC Remote"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "DisplayVersion" "${PRODUCT_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote" "NoRepair" 1
SectionEnd

Section "Uninstall"
  ClearErrors
  Delete "$INSTDIR\PCRemote.exe"
  Delete "$INSTDIR\AppleTVRemote.exe"
  IfErrors 0 +3
    MessageBox MB_OK|MB_ICONEXCLAMATION "Close PC Remote and Apple TV Remote and run the uninstaller again."
    Abort
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "PCRemote"
  StrCmp $0 '"$INSTDIR\PCRemote.exe"' 0 +2
    DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "PCRemote"
  Delete "$INSTDIR\README-Windows.md"
  Delete "$INSTDIR\Third-party-notices.txt"
  Delete "$INSTDIR\Uninstall.exe"
  Delete "$SMPROGRAMS\PC Remote\PC Remote.lnk"
  Delete "$SMPROGRAMS\PC Remote\Apple TV Remote.lnk"
  RMDir "$SMPROGRAMS\PC Remote"
  RMDir "$INSTDIR"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\PCRemote"
SectionEnd
