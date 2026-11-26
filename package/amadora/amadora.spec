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
# Horizon's release folder (build-horizon.sh), beside AMADORA at %{_prefix}/lib/amadora/horizon
if [ -d %{_sourcedir}/horizon ]; then
  mkdir -p %{buildroot}%{_prefix}/lib/amadora
  cp -R %{_sourcedir}/horizon %{buildroot}%{_prefix}/lib/amadora/horizon
fi

%files
%{_bindir}/amadora
%{_datadir}/icons/hicolor/256x256/apps/amadora.png
%{_datadir}/applications/amadora.desktop
%{_prefix}/lib/amadora
%license %{_datadir}/licenses/amadora/LICENSE
