{
 ***************************************************************************
 *                                                                         *
 *   This source is free software; you can redistribute it and/or modify   *
 *   it under the terms of the GNU General Public License as published by  *
 *   the Free Software Foundation; either version 2 of the License, or     *
 *   (at your option) any later version.                                   *
 *                                                                         *
 *   This code is distributed in the hope that it will be useful, but      *
 *   WITHOUT ANY WARRANTY; without even the implied warranty of            *
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *
 *   General Public License for more details.                              *
 *                                                                         *
 *   A copy of the GNU General Public License is available on the World    *
 *   Wide Web at <http://www.gnu.org/copyleft/gpl.html>. You can also      *
 *   obtain it by writing to the Free Software Foundation,                 *
 *   Inc., 51 Franklin Street - Fifth Floor, Boston, MA 02110-1335, USA.   *
 *                                                                         *
 ***************************************************************************

 Author: Balázs Székely
 Abstract:
   This unit allows OPM to interact with the Lazarus package system}

unit opkman_intf;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Dialogs, Controls, contnrs, fpjson,
  // IdeIntf
  LazIDEIntf, PackageIntf, PackageLinkIntf, PackageDependencyIntf, IDECommands,
  // OPM
  opkman_timer, opkman_downloader, opkman_serializablepackages, opkman_installer;

type

  { TOPMInterfaceEx }

  TOPMInterfaceEx = class(TOPMInterface)
  private
    FPackagesToInstall: TObjectList;
    FPackageDependecies: TObjectList;
    FPackageLinks: TObjectList;
    FWaitForIDE: TThreadTimer;
    procedure DoWaitForIDE(Sender: TObject);
    procedure DoUpdatePackageLinks(Sender: TObject);
    procedure InitOPM;
    procedure SynchronizePackages;
    procedure AddToInstallList(const AName, AURL: String);
    function Download(const ADstDir: String; AParentForm: TForm): TModalResult;
    function Extract(const ASrcDir, ADstDir: String; AParentForm: TForm;
      const AIsUpdate: Boolean = False): TModalResult;
    function Install(AParentForm: TForm; var AInstallStatus: TInstallStatus;
      var ANeedToRebuild: Boolean): TModalResult;
    function IsInLinkList(const AName, AURL: String): Boolean;
    function ResolveDependencies(AParentForm: TForm): TModalResult;
    function CanInstallPackages(AParentForm: TForm): TModalResult;
  public
    constructor Create;
    destructor Destroy; override;
  public
    function InstallPackages(APkgLinks: TList; AParentForm: TForm;
      var ANeedToRebuild: Boolean): TModalResult; override;
  end;

implementation

uses opkman_common, opkman_options, opkman_const, opkman_progressfrm, opkman_zipper,
     opkman_intf_PackageListFrm;

{ TOPMInterfaceEx }

constructor TOPMInterfaceEx.Create;
begin
  FPackageLinks := TObjectList.Create(False);
  FPackagesToInstall := TObjectList.Create(False);
  FPackageDependecies := TObjectList.Create(False);
  FWaitForIDE := TThreadTimer.Create;
  FWaitForIDE.Interval := 100;
  FWaitForIDE.OnTimer := @DoWaitForIDE;
  FWaitForIDE.StartTimer;
end;

destructor TOPMInterfaceEx.Destroy;
begin
  FPackageLinks.Clear;
  FPackageLinks.Free;
  FPackagesToInstall.Clear;
  FPackagesToInstall.Free;
  FPackageDependecies.Clear;
  FPackageDependecies.Free;
  PackageDownloader.Free;
  SerializablePackages.Free;
  Options.Free;
  InstallPackageList.Free;
  inherited Destroy;
end;

procedure TOPMInterfaceEx.DoWaitForIDE(Sender: TObject);
begin
  if Assigned(LazarusIDE) and Assigned(PackageEditingInterface) then
  begin
    InitOPM;
    FWaitForIDE.StopTimer;
    FWaitForIDE.Terminate;
  end;
end;

procedure TOPMInterfaceEx.InitOPM;
begin
  InitLocalRepository;
  Options := TOptions.Create(LocalRepositoryConfigFile);
  SerializablePackages := TSerializablePackages.Create;
  SerializablePackages.OnUpdatePackageLinks := @DoUpdatePackageLinks;
  PackageDownloader := TPackageDownloader.Create(Options.RemoteRepository[Options.ActiveRepositoryIndex]);
  InstallPackageList := TObjectList.Create(True);
  PackageDownloader.DownloadJSON(Options.ConTimeOut*1000);
end;

procedure TOPMInterfaceEx.DoUpdatePackageLinks(Sender: TObject);
begin
  SynchronizePackages;
end;

function TOPMInterfaceEx.IsInLinkList(const AName, AURL: String): Boolean;
var
  I: Integer;
  PackageLink: TPackageLink;
begin
  Result := False;
  for I := 0 to FPackageLinks.Count - 1 do
  begin
    PackageLink := TPackageLink(FPackageLinks.Items[I]);
    if (UpperCase(PackageLink.Name) = UpperCase(AName)) and (UpperCase(PackageLink.LPKUrl) = UpperCase(AURL)) then
    begin
      Result := True;
      Break;
    end;
  end;
end;

procedure TOPMInterfaceEx.SynchronizePackages;
var
  I, J: Integer;
  MetaPackage: TMetaPackage;
  LazPackage: TLazarusPackage;
  PackageLink: TPackageLink;
  FileName, Name, URL: String;
begin
  PkgLinks.ClearOnlineLinks;
  FPackageLinks.Clear;
  for I := 0 to SerializablePackages.Count - 1 do
  begin
    MetaPackage := SerializablePackages.Items[I];
    for J := 0 to MetaPackage.LazarusPackages.Count - 1 do
    begin
      LazPackage := TLazarusPackage(MetaPackage.LazarusPackages.Items[J]);
      FileName := Options.LocalRepositoryPackages + MetaPackage.PackageBaseDir + LazPackage.PackageRelativePath + LazPackage.Name;
      Name := StringReplace(LazPackage.Name, '.lpk', '', [rfReplaceAll, rfIgnoreCase]);
      URL := Options.RemoteRepository[Options.ActiveRepositoryIndex] + MetaPackage.RepositoryFileName;
      if not IsInLinkList(Name, URL) then
      begin
        PackageLink := PkgLinks.AddOnlineLink(FileName, Name, URL);
        if PackageLink <> nil then
        begin
          PackageLink.Version.Assign(LazPackage.Version);
          PackageLink.LPKFileDate := MetaPackage.RepositoryDate;
          FPackageLinks.Add(PackageLink);
        end;
      end;
    end;
  end;
end;

procedure TOPMInterfaceEx.AddToInstallList(const AName, AURL: String);
var
  I, J: Integer;
  MetaPackage: TMetaPackage;
  LazPackage: TLazarusPackage;
begin
  for I := 0 to SerializablePackages.Count - 1 do
  begin
    MetaPackage := SerializablePackages.Items[I];
    for J := 0 to MetaPackage.LazarusPackages.Count - 1 do
    begin
      LazPackage := TLazarusPackage(MetaPackage.LazarusPackages.Items[J]);
      if (UpperCase(LazPackage.Name) = UpperCase(AName)) and
         (UpperCase(Options.RemoteRepository[Options.ActiveRepositoryIndex] + MetaPackage.RepositoryFileName) = UpperCase(AURL)) then
      begin
        FPackagesToInstall.Add(LazPackage);
        Break;
      end;
    end;
  end;
end;

function TOPMInterfaceEx.ResolveDependencies(AParentForm: TForm): TModalResult;
var
  I, J: Integer;
  PackageList: TObjectList;
  PkgFileName: String;
  DependencyPkg: TLazarusPackage;
  MetaPkg: TMetaPackage;
  Msg: String;
begin
  Result := mrNone;
  FPackageDependecies.Clear;
  for I := 0 to FPackagesToInstall.Count - 1 do
  begin
    PackageList := TObjectList.Create(True);
    try
      SerializablePackages.GetPackageDependencies(TLazarusPackage(FPackagesToInstall.Items[I]).Name, PackageList, True, True);
      for J := 0 to PackageList.Count - 1 do
      begin
        PkgFileName := TPackageDependency(PackageList.Items[J]).PkgFileName + '.lpk';
        DependencyPkg := SerializablePackages.FindLazarusPackage(PkgFileName);
        if DependencyPkg <> nil then
        begin
          if (not DependencyPkg.Checked) and
              (UpperCase(TLazarusPackage(FPackagesToInstall.Items[I]).Name) <> UpperCase(PkgFileName)) and
               ((SerializablePackages.IsDependencyOk(TPackageDependency(PackageList.Items[J]), DependencyPkg)) and
                ((not (DependencyPkg.PackageState = psInstalled)) or ((DependencyPkg.PackageState = psInstalled) and (not (SerializablePackages.IsInstalledVersionOk(TPackageDependency(PackageList.Items[J]), DependencyPkg.InstalledFileVersion)))))) then
          begin
            if (Result = mrNone) or (Result = mrYes) then
              begin
                Msg := Format(rsMainFrm_rsPackageDependency0, [TLazarusPackage(FPackagesToInstall.Items[I]).Name, DependencyPkg.Name]);
                Result := MessageDlgEx(Msg, mtConfirmation, [mbYes, mbYesToAll, mbNo, mbNoToAll, mbCancel], AParentForm);
                if Result in [mrNo, mrNoToAll] then
                  if MessageDlgEx(rsMainFrm_rsPackageDependency1, mtInformation, [mbYes, mbNo], AParentForm) <> mrYes then
                    Exit(mrCancel);
                if (Result = mrNoToAll) or (Result = mrCancel) then
                  Exit(mrCancel);
              end;
              if Result in [mrYes, mrYesToAll] then
              begin
                DependencyPkg.Checked := True;
                MetaPkg := SerializablePackages.FindMetaPackageByLazarusPackage(DependencyPkg);
                if MetaPkg <> nil then
                  MetaPkg.Checked := True;
                FPackageDependecies.Add(DependencyPkg);
              end;
          end;
        end;
      end;
    finally
      PackageList.Free;
    end;
  end;
  Result := mrOk;
end;

function TOPMInterfaceEx.CanInstallPackages(AParentForm: TForm): TModalResult;
var
  I: Integer;
  LazarusPkg: TLazarusPackage;
  MetaPkg: TMetaPackage;
begin
  Result := mrCancel;
  IntfPackageListFrm := TIntfPackageListFrm.Create(AParentForm);
  try
    IntfPackageListFrm.PopupMode := pmExplicit;
    IntfPackageListFrm.PopupParent := AParentForm;
    IntfPackageListFrm.PopulateTree(FPackagesToInstall);
    IntfPackageListFrm.ShowModal;
    if IntfPackageListFrm.ModalResult = mrOk then
    begin
      for I := FPackagesToInstall.Count - 1 downto 0 do
      begin
        LazarusPkg := TLazarusPackage(FPackagesToInstall.Items[I]);
        if IntfPackageListFrm.IsLazarusPackageChecked(LazarusPkg.Name) then
        begin
          LazarusPkg.Checked := True;
          MetaPkg := SerializablePackages.FindMetaPackageByLazarusPackage(LazarusPkg);
          if MetaPkg <> nil then
            MetaPkg.Checked := True;
        end
        else
          FPackagesToInstall.Delete(I);
      end;
      if FPackagesToInstall.Count > 0 then
        Result := mrOK;
    end;
  finally
    IntfPackageListFrm.Free;
  end;
end;

function TOPMInterfaceEx.Download(const ADstDir: String; AParentForm: TForm): TModalResult;
begin
  ProgressFrm := TProgressFrm.Create(AParentForm);
  try
    ProgressFrm.SetupControls(0);
    PackageDownloader.OnPackageDownloadProgress := @ProgressFrm.DoOnPackageDownloadProgress;
    PackageDownloader.OnPackageDownloadError := @ProgressFrm.DoOnPackageDownloadError;
    PackageDownloader.OnPackageDownloadCompleted := @ProgressFrm.DoOnPackageDownloadCompleted;
    PackageDownloader.DownloadPackages(ADstDir);
    Result := ProgressFrm.ShowModal;
  finally
    ProgressFrm.Free;
  end;
end;


function TOPMInterfaceEx.Extract(const ASrcDir, ADstDir: String;
  AParentForm: TForm; const AIsUpdate: Boolean): TModalResult;
begin
  ProgressFrm := TProgressFrm.Create(AParentForm);
  try
    PackageUnzipper := TPackageUnzipper.Create;
    try
      ProgressFrm.SetupControls(1);
      PackageUnzipper.OnZipProgress := @ProgressFrm.DoOnZipProgress;
      PackageUnzipper.OnZipError := @ProgressFrm.DoOnZipError;
      PackageUnzipper.OnZipCompleted := @ProgressFrm.DoOnZipCompleted;
      PackageUnzipper.StartUnZip(ASrcDir, ADstDir, AIsUpdate);
      Result := ProgressFrm.ShowModal;
    finally
      if Assigned(PackageUnzipper) then
        PackageUnzipper := nil;
    end;
  finally
    ProgressFrm.Free;
  end;
end;

function TOPMInterfaceEx.Install(AParentForm: TForm; var AInstallStatus: TInstallStatus;
  var ANeedToRebuild: Boolean): TModalResult;
begin
  ProgressFrm := TProgressFrm.Create(AParentForm);
  try
    ProgressFrm.SetupControls(2);
    Result := ProgressFrm.ShowModal;
    if Result = mrOk then
    begin
      AInstallStatus := ProgressFrm.InstallStatus;
      ANeedToRebuild := ProgressFrm.NeedToRebuild;
    end;
  finally
    ProgressFrm.Free;
  end;
end;


function TOPMInterfaceEx.InstallPackages(APkgLinks: TList; AParentForm: TForm;
  var ANeedToRebuild: Boolean): TModalResult;
var
  I: Integer;
  InstallStatus: TInstallStatus;
begin
  FPackagesToInstall.Clear;
  for I := 0 to APkgLinks.Count - 1 do
    AddToInstallList(TPackageLink(APkgLinks.Items[I]).Name + '.lpk', TPackageLink(APkgLinks.Items[I]).LPKUrl);

  Result := CanInstallPackages(AParentForm);
  if Result = mrCancel then
    Exit;

  Result := ResolveDependencies(AParentForm);
  if Result = mrCancel then
     Exit;
  for I := 0 to FPackageDependecies.Count - 1 do
    FPackagesToInstall.Insert(0, FPackageDependecies.Items[I]);


  PackageAction := paInstall;
  if SerializablePackages.DownloadCount > 0 then
  begin
    Result := Download(Options.LocalRepositoryArchive, AParentForm);
    SerializablePackages.GetPackageStates;
  end;

  if Result = mrOk then
  begin
    if SerializablePackages.ExtractCount > 0 then
    begin
      Result := Extract(Options.LocalRepositoryArchive, Options.LocalRepositoryPackages, AParentForm);
      SerializablePackages.GetPackageStates;
    end;

    if Result = mrOk then
    begin
      if Options.DeleteZipAfterInstall then
        SerializablePackages.DeleteDownloadedZipFiles;
      if SerializablePackages.InstallCount > 0 then
      begin
        InstallStatus := isFailed;
        ANeedToRebuild := False;
        Result := Install(AParentForm, InstallStatus, ANeedToRebuild);
        if Result = mrOk then
        begin
          SerializablePackages.MarkRuntimePackages;
          SerializablePackages.GetPackageStates;
          if (ANeedToRebuild) and ((InstallStatus = isSuccess) or (InstallStatus = isPartiallyFailed)) then
            ANeedToRebuild :=  MessageDlgEx(rsOPMInterfaceRebuildConf, mtConfirmation, [mbYes, mbNo], AParentForm) = mrYes;
        end;
      end;
    end;
  end;
  SerializablePackages.RemoveErrorState;
  SerializablePackages.RemoveCheck;
end;

end.
