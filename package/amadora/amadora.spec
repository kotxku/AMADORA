Name:           amadora
Version:        0.1.0
Release:        1
Summary:        AMADORA desktop Minecraft launcher
License:        MIT
URL:            https://github.com/kotxku/AMADORA
AutoReqProv:    yes

%description
Development desktop edition of AMADORA based on Pandora Launcher.

%install
install -Dm755 %{_sourcedir}/pandora_launcher %{buildroot}%{_bindir}/amadora
install -Dm644 %{_sourcedir}/icon_256x256.png %{buildroot}%{_datadir}/icons/hicolor/256x256/apps/amadora.png
install -Dm644 %{_sourcedir}/amadora.desktop %{buildroot}%{_datadir}/applications/amadora.desktop
install -Dm644 %{_sourcedir}/LICENSE %{buildroot}%{_datadir}/licenses/amadora/LICENSE

%files
%{_bindir}/amadora
%{_datadir}/icons/hicolor/256x256/apps/amadora.png
%{_datadir}/applications/amadora.desktop
%license %{_datadir}/licenses/amadora/LICENSE
