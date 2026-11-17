Unicode true
!include "MUI2.nsh"
Name "AMADORA"
OutFile "..\..\AMADORA-Windows-x86_64-Setup.exe"
InstallDir "$LOCALAPPDATA\Programs\AMADORA"
RequestExecutionLevel user
!define MUI_ICON "..\amadora.ico"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "..\..\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "English"
Section "AMADORA"
 SetOutPath "$INSTDIR"
 File /oname=AMADORA.exe "..\..\target\x86_64-pc-windows-msvc\release\pandora_launcher.exe"
 File "..\..\LICENSE"
 WriteUninstaller "$INSTDIR\Uninstall.exe"
 CreateDirectory "$SMPROGRAMS\AMADORA"
 CreateShortcut "$SMPROGRAMS\AMADORA\AMADORA.lnk" "$INSTDIR\AMADORA.exe"
 WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AMADORA" "DisplayName" "AMADORA"
 WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AMADORA" "UninstallString" '"$INSTDIR\Uninstall.exe"'
 WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AMADORA" "DisplayIcon" "$INSTDIR\AMADORA.exe"
SectionEnd
Section "Uninstall"
 Delete "$INSTDIR\AMADORA.exe"
 Delete "$INSTDIR\LICENSE"
 Delete "$INSTDIR\Uninstall.exe"
 RMDir "$INSTDIR"
 Delete "$SMPROGRAMS\AMADORA\AMADORA.lnk"
 RMDir "$SMPROGRAMS\AMADORA"
 DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\AMADORA"
SectionEnd
