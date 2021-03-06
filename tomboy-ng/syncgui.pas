unit SyncGUI;
{
 * Copyright (C) 2017 David Bannon
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
 * LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
 * OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
 * WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
}

{	History
	2017/12/06	Marked FileSync debug mode off to quieten console output a little
	2017/12/30  Changed above DebugMode to VerboseMode
	2017/12/30  We now call IndexNotes() after a sync. Potentially slow.
	2017/12/30  Added a seperate procedure to do manual Sync, its called
				by a timer to ensure we can see dialog before it starts.
	2018/01/01  Added ID in sync report to make it easier to track errors.
	2018/01/01  Set goThumbTracking true so contents of scroll box glide past as
    			you move the "Thumb Slide".
	2018/01/01  Changed ModalResult for cancel button to mrCancel
	2018/01/08  Tidied up message box text displayed when a sync conflict happens.
	2018/01/25  Changes to support Notebooks
    2018/01/04  Forced a screen update before manual sync so user knows whats happening.
    2018/04/12  Added ability to call MarkNoteReadOnly() to cover case where user has unchanged
                note open while sync process downloads or deletes that note from disk.
    2018/04/13  Taught MarkNoteReadOnly() to also delete ref in NoteLister to a sync deleted note
    2018/05/12  Extensive changes - MainUnit is now just that. Only change here relates
                to naming of MainUnit and SearchUnit.
    2018/05/21  Show any sync errors as hints in the StringGrid.
    2018/06/02  Honor a cli --debug-sync
    2018/06/14  Update labels when transitioning from Testing Sync to Manual Sync
    2018/08/14  Added SDiff to replace clumbsy dialog when sync clash happens.
    2018/08/18  Improved test/reporting of file access during sync
    2018/10/25  New sync model. Much testing, support for Tomdroid.
    2018/10/28  Much tweaking and bug fixing.
    2018/10/29  Tell TB_Sdiff about note title before showing it.
    2018/10/30  Don't show SyNothing in sync report
    2018/11/04  Added support to update in memory NoteList after a sync.
}

{$mode objfpc}{$H+}




interface

uses
		Classes, SysUtils, FileUtil, Forms, Controls, Graphics, Dialogs, ExtCtrls,
		StdCtrls, Grids, Syncutils;

type

		{ TFormSync }

  TFormSync = class(TForm)
				ButtonSave: TButton;
				ButtonCancel: TButton;
				ButtonClose: TButton;
				Label1: TLabel;
				Label2: TLabel;
				Memo1: TMemo;
				Panel1: TPanel;
				Panel2: TPanel;
				Panel3: TPanel;
				Splitter3: TSplitter;
				StringGridReport: TStringGrid;
				procedure ButtonCancelClick(Sender: TObject);
				procedure ButtonCloseClick(Sender: TObject);
    			procedure ButtonSaveClick(Sender: TObject);
				procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
                procedure FormHide(Sender: TObject);
                { At Show, depending on SetUpSync, we'll either go ahead and do it, any
                  error is fatal or, if True, walk user through process. }
				procedure FormShow(Sender: TObject);
                procedure StringGridReportGetCellHint(Sender: TObject; ACol, ARow: Integer;
                                  var HintText: String);
		private
                FormShown : boolean;
                LocalTimer : TTimer;
                procedure AdjustNoteList();
                procedure AfterShown(Sender : TObject);
                    // Display a summary of sync actions to user.
                procedure DisplaySync();
                    { Called when user wants to join a (possibly uninitialised) Repo,
                      will handle some problems with user's help. }
                procedure JoinSync;
                    { Called to do a sync assuming its all setup. Any problem is fatal }
                procedure ManualSync;
                    { Populates the string grid with details of notes to be actioned }
                procedure ShowReport;
            	//procedure TestRepo();
        		//procedure DoSetUp();

		public

                Transport : TSyncTransPort;

                    // A string containg a URL to remote repo, just a dir for FileSync
              	RemoteRepo : String;
                LocalConfig, NoteDirectory : ANSIString;
                    { Indicates we are doing a setup User has already agreed to abandon any
                      existing Repo but we don't know if indicated spot already contains a
                      repo or, maybe we want to make one. }
              	SetupSync : boolean;
                    { we will pass address of this function to Sync }
                procedure MarkNoteReadOnly(const Filename : string; const WasDeleted : Boolean = False);
                    { we will pass address of this function to Sync }
                function Proceed(const ClashRec : TClashRecord) : TSyncAction;
		end;

var
		FormSync: TFormSync;

implementation

{ In SetupFileSync mode, does a superficial, non writing, test OnShow() user
  can then click 'OK' and we'd do a real sync, exit and settings saved in calling
  process.
}

uses LazLogger, SearchUnit, TB_SDiff, Sync;
{$R *.lfm}

var
        ASync : TSync;
{ TFormSync }


procedure TFormSync.MarkNoteReadOnly(const Filename : string; const WasDeleted : Boolean = False);
begin
    SearchForm.MarkNoteReadOnly(FileName, WasDeleted);
end;

function TFormSync.Proceed(const ClashRec : TClashRecord) : TSyncAction;
var
    SDiff : TFormSDiff;
    //Res : integer;
begin
    SDiff := TFormSDiff.Create(self);
    SDiff.RemoteFilename := ClashRec.ServerFileName;
    SDiff.LocalFilename := ClashRec.LocalFileName;
    SDiff.NoteTitle := ClashRec.Title;
    case SDiff.ShowModal of
            mrYes      : Result := SyDownLoad;
            mrNo       : Result := SyUpLoadEdit;
            mrNoToAll  : Result := SyAllLocal;
            mrYesToAll : Result := SyAllRemote;
            mrAll      : Result := SyAllNewest;
            mrClose    : Result := SyAllOldest;
    else
            Result := SyUnSet;      // Thats an ERROR !  What are you doing about it ?
    end;
    SDiff.Free;
    // Use Remote, Yellow is mrYes, File1
    // Use Local, Aqua is mrNo, File2
end;

procedure TFormSync.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
	FreeandNil(ASync);          // probably not necessary but ....
end;

procedure TFormSync.FormHide(Sender: TObject);
begin
    if LocalTimer = Nil then exit();
    LocalTimer.Free;
    LocalTimer := nil;
end;




procedure TFormSync.DisplaySync();
var
    UpNew, UpEdit, Down, DelLoc, DelRem, Clash, DoNothing, Errors : integer;
begin
    ASync.ReportMetaData(UpNew, UpEdit, Down, DelLoc, DelRem, Clash, DoNothing, Errors);
    Memo1.Append('New Uploads    ' + inttostr(UpNew));
    Memo1.Append('Edit Uploads   ' + inttostr(UpEdit));
    Memo1.Append('Downloads      ' + inttostr(Down));
    Memo1.Append('Local Deletes  ' + inttostr(DelLoc));
    Memo1.Append('Remote Deletes ' + inttostr(DelRem));
    Memo1.Append('Clashes        ' + inttostr(Clash));
    Memo1.Append('Do Nothing     ' + inttostr(DoNothing));
    Memo1.Append('ERRORS (see consol log) ' + inttostr(Errors));
    // debugln('Display Sync called, DoNothings is ' + inttostr(DoNothing));
end;

    // User is only allowed to press Cancel or Save when this is finished.
procedure TFormSync.JoinSync;
var
    SyncAvail : TSyncAvailable;
    // ASync : TSync;
    // UpNew, UpEdit, Down, DelLoc, DelRem, Clash, DoNothing : integer;
begin
    freeandnil(ASync);
	ASync := TSync.Create;
    Label1.Caption:='Testing Repo ....';
    Application.ProcessMessages;
    ASync.ProceedFunction:= @Proceed;
//    ASync.MarkNoteReadOnlyProcedure := @MarkNoteReadOnly;
    ASync.DebugMode := Application.HasOption('s', 'debug-sync');
	ASync.NotesDir:= NoteDirectory;
	ASync.SyncAddress := RemoteRepo;        // This is 'some' URL
	ASync.ConfigDir := LocalConfig;
    ASync.RepoAction:=RepoJoin;
    Async.SetTransport(TransPort);
    SyncAvail := ASync.TestConnection();
    if SyncAvail = SyncNoRemoteRepo then
        if mrYes = QuestionDlg('Advice', 'Create a new Repo ?', mtConfirmation, [mrYes, mrNo], 0) then begin
            ASync.RepoAction:=RepoNew;
            SyncAvail := ASync.TestConnection();
        end;
    if SyncAvail <> SyncReady then begin
        showmessage('Unable to proceed because ' + ASync.ErrorString);
        ModalResult := mrCancel;
    end;
    Label1.Caption:='Looking at notes ....';
    Application.ProcessMessages;
    ASync.TestRun := True;
    if ASync.StartSync() then begin
        DisplaySync();
        ShowReport();
        Label1.Caption:='Ready to proceed ....';
        Label2.Caption := 'Press Save and Sync if this looks OK';
        ButtonSave.Enabled := True;
    end  else
        Showmessage('A Sync Error occured ' + ASync.ErrorString);
    ButtonCancel.Enabled := True;
end;

procedure TFormSync.AfterShown(Sender : TObject);
begin
    LocalTimer.Enabled := False;             // Don't want to hear from you again
    if SetUpSync then begin
        JoinSync();
    end else
        ManualSync();
end;

procedure TFormSync.FormShow(Sender: TObject);
begin
    FormShown := False;
    Label2.Caption := 'Please wait a minute or two ...';
    Memo1.Clear;
    StringGridReport.Clear;
    ButtonSave.Enabled := False;
    ButtonClose.Enabled := False;
    ButtonCancel.Enabled := False;
    // We call a timer to get out of OnShow so ProcessMessages works as expected
    LocalTimer := TTimer.Create(Nil);
    LocalTimer.OnTimer:= @AfterShown;
    LocalTimer.Interval:=500;
    LocalTimer.Enabled := True;
end;

        // User is only allowed to press Close when this is finished.
procedure TFormSync.ManualSync();
begin
    Label1.Caption := 'Testing Sync';
    Application.ProcessMessages;
	ASync := TSync.Create;
    try
        ASync.ProceedFunction:= @Proceed;
//        ASync.MarkNoteReadOnlyProcedure := @MarkNoteReadOnly;
        ASync.DebugMode := Application.HasOption('s', 'debug-sync');
	    ASync.NotesDir:= NoteDirectory;
	    ASync.SyncAddress := RemoteRepo;        // This is 'some' URL
	    ASync.ConfigDir := LocalConfig;
        ASync.RepoAction:=RepoUse;
        Async.SetTransport(TransPort);
        if Syncready <> ASync.TestConnection() then begin
            showmessage('Unable to sync because ' + ASync.ErrorString);
            FormSync.ModalResult := mrAbort;
        end;
        if ModalResult <> mrAbort then begin    // Puzzel, setting mrAbort should have closed....
            Label1.Caption:= 'Running Sync';
            Application.ProcessMessages;
            ASync.TestRun := False;
            ASync.StartSync();
            DisplaySync();
            ShowReport();
            AdjustNoteList();                              // ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
            Label1.Caption:='All Done';
            Label2.Caption := 'Press Close';
            ButtonClose.Enabled := True;
        end;
    finally
        FreeandNil(ASync);
    end;
end;
procedure TFormSync.AdjustNoteList();
var
    DeletedList, DownList : TStringList;
    Index : integer;
begin
    DeletedList := TStringList.Create;
    DownList := TStringList.Create;
 	with ASync.NoteMetaData do begin
		for Index := 0 to Count -1 do begin
            if Items[Index]^.Action = SyDeleteLocal then
                DeletedList.Add(Items[Index]^.ID);
            if Items[Index]^.Action = SyDownload then
                DownList.Add(Items[Index]^.ID);
        end;
    end;
    if (DeletedList.Count > 0) or (DownList.Count > 0) then
        SearchForm.ProcessSyncUpdates(DeletedList, DownList);
   FreeandNil(DeletedList);
   FreeandNil(DownList);
end;

procedure TFormSync.ShowReport();
var
        Index : integer;
        Rows : integer = 0;
begin
     	with ASync.NoteMetaData do begin
    		for Index := 0 to Count -1 do begin
                if Items[Index]^.Action <> SyNothing then begin
                        StringGridReport.InsertRowWithValues(Rows
                	        , [ASync.NoteMetaData.ActionName(Items[Index]^.Action)
                            , Items[Index]^.Title, Items[Index]^.ID]);
                        inc(Rows);
                end;
    		end
    	end;
        StringGridReport.AutoSizeColumn(0);
        StringGridReport.AutoSizeColumn(1);
        if  Rows = 0 then
            Memo1.Append('No notes needed syncing. You need to write more.')
        else Memo1.Append(inttostr(ASync.NoteMetaData.Count) + ' notes were dealt with.');
end;

procedure TFormSync.StringGridReportGetCellHint(Sender: TObject; ACol,
  ARow: Integer; var HintText: String);
begin
// HintText := FileSync.ReportList.Items[ARow]^.Message;
end;

procedure TFormSync.ButtonCancelClick(Sender: TObject);
begin
    ModalResult := mrCancel;
end;

procedure TFormSync.ButtonCloseClick(Sender: TObject);
begin
	ModalResult := mrOK;
end;

    // This only ever happens during a Join .....
procedure TFormSync.ButtonSaveClick(Sender: TObject);
begin
    Label2.Caption:='OK, I''ll do it, please wait .....';
    Label1.Caption:='First Time Sync';
    Memo1.Clear;
    Application.ProcessMessages;
    ButtonCancel.Enabled := False;
    ButtonSave.Enabled := False;
    ASync.TestRun := False;
    if ASync.StartSync() then begin
        DisplaySync();
        ShowReport();
        AdjustNoteList();
        Label1.Caption:='All Done';
        Label2.Caption := 'Press Close';
    end  else
        Showmessage('A Sync Error occured ' + ASync.ErrorString);
    ButtonClose.Enabled := True;
end;

end.

