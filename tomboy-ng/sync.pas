unit sync;
{
    A Unit to manage tomboy-ng sync behaviour.
    Copyright (C) 2018 David Bannon
    See attached licence file.
}

{$mode objfpc}{$H+}

{ How to use this Unit -

    Syncutils will probably be needed in Interface Uses
    Sync in implementation of Uses.

  if we belive we have an existion Repo accessible -

  	ASync := TSync.Create();
	ASync.DebugMode:=True;
	ASync.TestRun := ? ;
	ASync.ProceedFunction:=@Proceed;    // A higher level function that can resolve clashes
	ASync.NotesDir:= ?;
	ASync.ConfigDir := ?;
	ASync.SyncAddress := ?;
    ASync.RepoAction:= RepoUse;         // RepoUse says its all there, ready to go.
	Async.SetMode(SyncFile);            // SyncFile, SyncNextRuby ....
    SyncReady <> ASync.TestConnection() then    // something bad happened, SyncReady only
                                                // acceptable answer. Check ErrorString

  If joining an existing or making a new repo, set RepoAction to RepoJoin, if TestConnection
  returns SyncNoRemoteRepo then ask user if they want to create a new repo, try again with
  RepoNew.

  Other errors to be dealt with include -
  SyncXMLError, SyncNoRemoteDir, SyncBadRemote, SyncNoRemoteWrite ....

  -----------------------------------------------------------------------------


Operation of this unit -

Fistly, this unit depends on on the Trans unit, a virtual unit of which the TransFile
has been implemented and TransNet partially. Further Transport layers should be easily
made.

Two seperate approches are needed. In both cases we build a list of all the notes we
know about and what we plan to do for each. The list is built differently for each
case and, then, the same processes are applied to that list. Creating a new Repo is,
effectivly, a variation of the second.

---- Terms ----
LCD - Last Change Date
LSD - Last Sync Date
LocalDelete - a note that has been previously synced but is no longer mentioned in
              Remote Manifest, its been deleted elsewhere.
RemoteDelete - a note that has been previously synced but has been eleted locally,
              remove it from Repo.
NewUpLoad - a note the Repo has not seen before
EditUpLoad - a note, previusly synced and has been edited locally since last sync.


Some globals we'll need to know  -
- Repo, config and notes directory.
- Remote ServerID
- RemoteRevNo (except if its a new repo)
- Local Last Sync Date, as a string.
- Local Last Revision Number

TestConnection() will establish indicated Repo dir exists and we have write permission
there, does it look like an Existing Repo ? If an existing repo, get ServerID and
RemoteRevNo. If we are making a new connection, make a GUID and set those vars appropriatly.

The Model as implemented in tomboy-ng, October 2018

We call TestTransportEarly() and/or TestTransport()
Its tests and may, or may not populate NoteMetaData with remote notes.

We call StartSync() (not talking about Andro mode here.)
---------------------
RepoAction = RepoUse (that is, it all should be setup, just go and do it)
CheckUsingRev() Assigned a action to each existing entry in NoteMetaData based on the
    current revision number and notes present in NotesDir. Note this method is an alternative to CheckUsingLCD().
CheckRemoteDeletes() Marks remote deletes, that is notes that are mentioned in
    LocalManifets as having been synced in the past (but not deleted section) but
    were not listed in NoteMetaData at this stage because the Remote Server does not
    know about them. Note, this will override a local note that has been edited
    since last sync - should this be a clash ?
CheckLocalDeletes() looks at notes listed in LocalManifest as Deletes, it markes
    them, in NoteMetaData as DeleteRemote to be deleted from remote system (maybe
    just not mentioned in remote manifest any more).
CheckNewNotes() looks in Notes dir for any notes there that are not yet listed in
    NoteMetaData. These notes are UploadNew.

Call the General Write Behavour Block if not a TestRun.

RepoAction = RepoJoin
---------------------
CheckUsingLCD(True) Assignes an Action to each entry in NoteMetaData (which only
    contains entries from remote repo at this stage) based on last-change-date.
    If it finds a potential clash, aborts if it does not have last-change-date for
    the remote note. In that case, we recall LoadReopData(True) this time demanding
    last change date. And then run CheckUsingLCD again.  Note this method is an
    alternative to CheckUsingRev()
Because a join cannot use loacal manifest, we do not honour remote or local deletes.
CheckNewNotes() looks in Notes dir for any notes there that are not yet listed
    in NoteMetaData. These notes are UploadNew.

Call the General Write Behavour Block if not a TestRun.

RepoAction = RepoNew (if we determine, during a RepoJoin, that the dir we are pointing to does not contain a repo, we create one in this mode. Must always call RepoJoin first)
-----------------------
CheckNewNotes() looks in Notes dir for any notes there that are not yet listed in NoteMetaData (which, is, of course empty at this stage). These notes are UploadNew.
Call the General Write Behavour Block if not a TestRun.

General Write Behavour
----------------------
applies for all three cases above. Some methods are not relevent in some modes, they just
    return true when they detect that themselves.)
ProcessClashes()
DoDownLoads()
WriteRemoteManifest()   - writes out a local copy of remote manifest to be used later.
    We always write it (except in TestRun) but only call Transport to deal with it
    if we have notes changing.
DoDeletes() - Deletes from remote server. In current implementations, does nothing.
DoUploads()
DoDeleteLocal()
WriteLocalManifest()

Note, we want to write a new local manifest even if there are no note changes taking place, that way, we get an updated Last-Sync-Date and possibly updated revnumber. If we have not changed any files, then RevNo is the one we found in RemoteManifest. So, we must step through the write stack.

We make a half harted attempt to restore normality if we get to local manifest stage and somehow fail to write it out.
-----------------------------------------------------------------------------------

HISTROY
    2018/10/18  Memory leak in CheckUsingLCD(), StartSync() should not call processClashes()
                during a TestRun. Only during real thing.
    2018/10/22  CheckMetaData() was returning wrong value.
    2018/10/25  Much testing, support for Tomdroid.
    2018/10/28  Much tweaking and bug fixing.
    2018/10/29  Tell TB_Sdiff about note title before showing it.
    2018/11/03  Call checkmetadata before resolving clashes.
}

interface
uses
    Classes, SysUtils, SyncUtils;


type                       { ----------------- T S Y N C --------------------- }

  { TSync }

  TSync = class

  private
            // Generally an empty string but in Android/Tomdroid something we prefix
            // to local manifest file name to indicate which connection it relates to.
        ManPrefix : string;

        TransportMode : TSyncTransport;

            { Indicates an action to take on a Clash, the user can select this
            action when the first clash happens }
        ProceedAction : TSyncAction;

	         // Where we find Tomboy style notes
	    FNotesDir : string;
	         // Where we find config and local manifest files
        FConfigDir : string;

            { Scans Notes dir looking for each note in NoteMetaData. Any it finds
              are either clashes or SyNothing, anything left are downloads.
              If AssumeNoClash and we find a clash, unresolable 'cos LCD missing, ret False,
              (and expect LoadRepoData to be called again. Used when JOINING an existing repo.}
      function CheckUsingLCD(AssumeNoClash : boolean) : boolean;

            { Backs up and then removes any local local notes listed NoteMetaData as SyDeleteLocal }
      function DoDeleteLocal(): boolean;

            { Returns the title of given note, prefers the local version but if
              it does not exist, then "downloads" remote one }
      function GetNoteTitle(const ID : ANSIString; const Rev : integer): ANSIString;
      // function IDLooksOK(const ID: string): boolean;

            { Looks at a clash and determines if its an up or down depending on
              possible higher order TSyncActions such as newer, older }
      function ResolveAllClash(const Act : TSyncAction; const ID, FullRemoteFileName : ANSIString): TSyncAction;

          { Goes over NoteMetaData (which has only remote notes at this stage) assigning
            an Action to each. Only called when using an established sync connection. }
      function CheckUsingRev(): boolean;

        {Notes we have deleted (and existed) here since last sync are marked DeleteRemote
         because we must delete them from the server. For file sync, that means not
         mentioning them in remote manifest any more. Note that while it might seem
         unnecessary, we must inc the revision number.}
      procedure CheckLocalDeletes();

        { Scans over the notes directory for any note not mentioned in NoteMetaData
          and adds it as an syUploadNew as its a new note since last sync. Call
          after all the other methods that help build the NoteMetaDate. }
	  procedure CheckNewNotes();

        {if we have a note prev synced (ie, in local manifest) but not now in RemoteMetaData,
         it was deleted by another client, Mark these as DeleteLocal, will later backup and delete.}
      procedure CheckRemoteDeletes();

       // Just a debug procedure, dumps (some) contents of a list to console
      procedure DisplayNoteInfo(const meta: TNoteInfoList; const ListTitle : string);
            // Based on NoteMetaData, calls transport to delete notes from Server.
	  function DoDeletes(): boolean;

          { We call transport for all the notes in the list we need download.
          Transport does most of the work. In TestMode, does nothing }
	  function DoDownloads(): boolean;

            { Uploads any files it finds necessary in NoteMetaData. Returns false
              if anything goes wrong (such as a file error) }
	  function DoUploads(): boolean;

            {   Asks Transport for a list of the notes remote server knows about.
                If ForceLCD then make heroic efforts to get last-change-dates }
	  function LoadRepoData(ForceLCD : boolean): boolean;

            { Searches list for any clashes, refering each one to user. Done after
              list is filled out in case we want to ask user for general instrucions }
      procedure ProcessClashes();

        // Checks if local note exists, optionally returning with its last change date.
      function LocalNoteExists(const ID : string; out CDate: string; GetDate: boolean=false): Boolean;

        // Call this when we are resolving a sync clash. Note : not possible results make sense !
      function ProceedWith(const ID, FullRemoteFileName, NTitle: ANSIString): TSyncAction;

                { Reads through Local Manifest file, filling out LocalMetaData,
                LastSyncDateSt and CurrRev. If local manifest does not exist, still
                returns True but CurrRev=0 and LocalLastSyncDateSt='' }
      function ReadLocalManifest(): boolean;

            { Writes a local mainfest file. Assumes NoteMetaData contains valid data about
              new Rev numbers and for uploads, last-change-date. If WriteOK is false then
              don't rev number and don't mention new notes in local manifest.}
      function WriteLocalManifest(const WriteOK, NewRev : boolean) : boolean;

            { We write a remote manifest out localy if we have any uploads or to handle
              the delete from server a note that was deleted locally to do. Then, if
              TestMode is false, call Transport to deal with it. Writing it locally is fast
              and we get to check for and isolate any data errors. Initially
              written to $CONFIG/manifest.xml-remote and copied (moved ?).}
	  function WriteRemoteManifest(out NewRev: boolean): boolean;

   public
            // A passord, passed on to Trans for those Transports that need it.
            // Must be set (if needed) before SetTransport is called.
        Password : string;

            // Indicates what we want this unit to do. Set it and call TestConnection() repeatly...
       RepoAction : TRepoAction;

            // Records local manifests view of serverID, after succefull test,
            // it should be the remote manifest's one too.
        LocalLastSyncID : string;

          { the calling process must pass a function address to this var. It will
            be called if the sync process finds a sync class where both copies
            of a note have changed since last sync.}
        ProceedFunction : TProceedFunction;

          { The calling process must set this to the address of a function to call
            every time a local note is deleted or overwritten during Sync. Its to
            deal with the case where a note is open but unchanged during sync.  }
        MarkNoteReadOnlyProcedure : TMarkNotereadOnlyProcedure;

                // A URL or directory with trailing delim.
        SyncAddress : string;
                // Revision number the client is currently on
        CurrRev : integer;
                // A string of local last sync date. Empty if we have not synced before
                // Available iff we are in RepoUse mode after TestConnection()
        LocalLastSyncDateSt : string;
                // Last time this client synced (not this run), set and tested in call to StartSync()
                // Available iff we are in RepoUse mode after TestConnection()
        LocalLastSyncDate : TDateTime;
                // Write debug messages as we do things.
        DebugMode : boolean;

                // Determine what we'd do and write ref ver of manifests but don't move files around.
        TestRun : boolean;
                // A reason why something failed.
        ErrorString : string;
                // Data about notes in remote manifest that may need be copied down
        NoteMetaData : TNoteInfoList;
                // Data obtained from Local Manifest. Might be empty.....
        LocalMetaData : TNoteInfoList;

        procedure FSetConfigDir(Dir : string);
        property ConfigDir : string read FConfigDir write FSetConfigDir;

        procedure FSetNotesDir(Dir : string);
        Property NotesDir : string read FNotesDir write FSetNotesDir;

                { Reports on contents of a created and filled list }
	    procedure ReportMetaData(out UpNew, UpEdit, Down, DelLoc, DelRem, Clash, DoNothing, Errors: integer);

                { True=FileSync, False=Network Sync }
        function SetTransport(Mode : TSyncTransport) : TSyncAvailable;               // todo - use an enumerated type ....

                { Checks NoteMetaData for valid Actions, writes error to console.
                  Always returns True and does mark bad lines with Action=SyError
                  Also fills in note Title for notes we will do something with.}
        function CheckMetaData() : boolean;

            { May return : SyncXMLError, SyncNoRemoteDir, SyncNoRemoteWrite,
              SyncNoRemoteRepo, SyncBadRemote, SyncMismatch. Checks if the connecton
              looks viable, either (fileSync) it has right files there and write access
              OR (NetSync) network answers somehow (?). SyncReady can proceed to
              StartSync, else must do something first, setup new connect, consult user etc.}
        function TestConnection() : TSyncAvailable;

            { Do actual sync, but if TestRun=True just report on what you'd do.
              Assumes a Transport has been selected and remote address is set.
              We must already be a member of this sync, ie, its remote ID is recorded
              in our local manifest. }
      function StartSync() : boolean;

      constructor Create();

      destructor Destroy(); override;

  end;

implementation

{ TSync }

uses laz2_DOM, laz2_XMLRead, Trans, TransFile, TransNet, TransAndroid, LazLogger, LazFileUtils,
    FileUtil;

var
    Transport : TTomboyTrans;

constructor TSync.Create();
begin
    NoteMetaData := TNoteInfoList.Create;
    LocalMetaData := TNoteInfoList.Create;
    Transport := nil;
    MarkNoteReadonlyProcedure := nil;
    //NewRepo := False;
end;

destructor TSync.Destroy();
begin
    FreeandNil(LocalMetaData);
    FreeandNil(NoteMetaData);
    FreeandNil(Transport);
    inherited Destroy();
end;

function TSync.LocalNoteExists(const ID : string; out CDate : string; GetDate : boolean = false) : Boolean;
var
	Doc : TXMLDocument;
	Node : TDOMNode;
    //LastChange : string;
begin
    if not FileExists(NotesDir + ID + '.note') then exit(False);
    if not GetDate then exit(True);
	try
		ReadXMLFile(Doc, NotesDir + ID + '.note');
		Node := Doc.DocumentElement.FindNode('last-change-date');
        if assigned(node) then
            CDate := Node.FirstChild.NodeValue
        else
            CDate := '';
	finally
        Doc.free;
    end;
end;


{ =================   E X T E R N A L   C A L L   O U T S ===========================}


function TSync.ProceedWith(const ID, FullRemoteFileName, NTitle : ANSIString) : TSyncAction;
var
    ClashRec : TClashRecord;
    //ChangeDate : ANSIString;
begin
    // Note - we no longer fill in all of clash record, let sdiff unit work it out.
    ClashRec.NoteID := ID;
    ClashRec.Title:= NTitle;
    ClashRec.ServerFileName := FullRemoteFileName;
    ClashRec.LocalFileName := self.NotesDir + ID + '.note';
    Result := ProceedFunction(Clashrec);
    if Result in [SyAllOldest, SyAllNewest, SyAllLocal, SyAllRemote] then
        ProceedAction := Result;
end;

function TSync.ResolveAllClash(const Act : TSyncAction; const ID, FullRemoteFileName : ANSIString) : TSyncAction;
var
    Temp : string;
begin
    case Act of
        SyAllLocal : exit(SyUpLoadEdit);
        SyAllRemote : exit(SyDownLoad);
        SyAllNewest : if GetGMTFromStr(GetNoteLastChangeSt(NotesDir + ID + '.note', Temp))
                            >  GetGMTFromStr(GetNoteLastChangeSt(FullRemoteFileName, Temp)) then
                        exit(SyUploadEdit)
                      else
                        exit(SyDownLoad);
        SyAllOldest :  if GetGMTFromStr(GetNoteLastChangeSt(NotesDir + ID + '.note', Temp))
                            <  GetGMTFromStr(GetNoteLastChangeSt(FullRemoteFileName, Temp)) then
                        exit(SyUploadEdit)
                      else
                        exit(SyDownLoad);
    end;
end;

procedure TSync.ProcessClashes();
var
    Index : integer;
    RemoteNote : string;
begin
    for Index := 0 to NoteMetaData.Count -1 do
        with NoteMetaData.Items[Index]^ do begin
            if Action = SyClash then begin
                RemoteNote := Transport.DownLoadNote(ID, Rev);
                if ProceedAction = SyUnSet then begin       // let user decide
                    Action := ProceedWith(ID, RemoteNote, NoteMetaData.Items[Index]^.Title);
                    if Action in [SyAllOldest, SyAllNewest, SyAllLocal, SyAllRemote] then
                        Action := ResolveAllClash(Action, ID, RemoteNote);
                end else
                    Action := ResolveAllClash(ProceedAction, ID, RemoteNote);  // user has already said "all something"
            end;
    end;
end;




procedure TSync.ReportMetaData(out UpNew, UpEdit, Down, DelLoc, DelRem, Clash, DoNothing, Errors : integer);
var
    Index : integer;
begin
    UpNew := 0; UpEdit := 0; Down := 0; Errors := 0;
    DelLoc := 0; DelRem := 0; DoNothing := 0; Clash := 0;
    for Index := 0 to NoteMetaData.Count -1 do begin
        case NoteMetaData.Items[Index]^.Action of
            SyUpLoadNew : inc(UpNew);
            SyUpLoadEdit : inc(UpEdit);
            SyDownLoad : inc(Down);
            SyDeleteLocal : inc(DelLoc);
            SyDeleteRemote : inc(DelRem);
            SyClash : inc(Clash);
            SyNothing : inc(DoNothing);
            SyError : inc(Errors);
		end;
    end;
end;

function TSync.CheckMetaData(): boolean;
var
    Index : integer;
begin
    Result := True;
    ErrorString := '';
    for Index := 0 to NoteMetaData.Count -1 do begin
        if NoteMetaData[Index]^.Action = SyUnSet then begin
            Debugln('ERROR note not assigned ' + NoteMetaData[Index]^.ID + ' '
                   + NoteMetaData.ActionName(NoteMetaData[Index]^.Action) + '  '
                   + NoteMetaData.ActionName(NoteMetaData[Index]^.Action));
            result := False;
        end;
        if IDLooksOK(NoteMetaData[Index]^.ID) then begin
            if NoteMetaData[Index]^.Action in [SyNothing, SyUploadNew, SyUpLoadEdit, SyDownLoad,
                    SyDeleteLocal, SyDeleteRemote, SyClash] then
                NoteMetaData[Index]^.Title := GetNoteTitle(NoteMetaData[Index]^.ID, NoteMetaData[Index]^.Rev)
        end else begin
            NoteMetaData[Index]^.Title := GetNoteTitle(NoteMetaData[Index]^.ID, NoteMetaData[Index]^.Rev);
            Debugln('ERROR - invalid ID detected when CheckMetaData [' + NoteMetaData[Index]^.ID + ']');
            NoteMetaData[Index]^.Action := SyError;
            ErrorString := 'ERROR - invalid ID detected when CheckMetaData [' + NoteMetaData[Index]^.ID + ']';
        end;
    end;
    if debugmode then
       debugln('CheckMetaData - NoteMetaData has ' + inttostr(NoteMetaData.Count) + ' entries.');
end;

function TSync.GetNoteTitle(const ID : ANSIString; const Rev : integer) : ANSIString;
var
        Doc : TXMLDocument;
        Node : TDOMNode;
        FileName : string;
begin
    Result := 'File Not Found';
    if FileExistsUTF8(NotesDir + ID + '.note') then
        FileName := NotesDir + ID + '.note'
    else FileName := Transport.DownLoadNote(ID, Rev);
    if FileExistsUTF8(FileName) then begin
        try
            Result := 'Unknown Title';
            try
                ReadXMLFile(Doc, FileName);
                Node := Doc.DocumentElement.FindNode('title');
                Result := Node.FirstChild.NodeValue;
            except on EXMLReadError do
                Result := 'Note has no Title ' + FileName;
                on EAccessViolation do
                    Result := 'Access Violation ' + FileName;
            end;
        finally
            Doc.free;
        end;
    end else begin
        debugln('ERROR - cannot get title for ' + FileName);
        result := 'ERROR getting Title';
    end;
end;



function TSync.TestConnection(): TSyncAvailable;
{var
    XServerID : string;}
begin
    if RepoAction = RepoNew then begin
        LocalLastSyncDate := 0;
        LocalLastSyncDateSt := '';
        Transport.RemoteServerRev:=-1;
        Transport.ANewRepo:= True;
        // means we should prepare for a new repo (but not make it yet), don't check for files.
    end;
    if RepoAction = RepoUse then begin
	    if not ReadLocalManifest() then exit(SyncXMLError);    // Error in local mainfest, OK or no manifest=true
	    LocalLastSyncDate :=  GetGMTFromStr(LocalLastSyncDateSt);
	    if LocalLastSyncDate < 1.0 then begin
		    ErrorString := 'Invalid last sync date in local manifest ' + LocalLastSyncDateSt;
		    exit(SyncXMLError);
        end;
    end;
    if RepoAction = RepoJoin then begin
        LocalLastSyncDate := 0;
        LocalLastSyncDateSt := '';
    end;
    Result := Transport.TestTransport();
    if Result <> SyncReady then begin
      ErrorString := Transport.ErrorString;
      exit;
    end;
    if DebugMode then begin
        debugln('CurrRev=' + inttostr(CurrRev) + '   Last Sync=' + LocalLastSyncDateSt
                        + '   Local Entries=' + inttostr(LocalMetaData.Count));
        debugln('Config=' + ConfigDir + ' NotesDir=' + NotesDir);
    end;
    if RepoAction = RepoUse then
	    if Transport.ServerID <> LocalLastSyncID then begin
	        ErrorString := 'ServerID Mismatch';
            if DebugMode then
                debugln('ERROR Server ID Mismatch Remote ' + Transport.ServerID + ' and local ' + LocalLastSyncID);
	        exit(SyncMismatch);
		end;
    if Result = SyncReady then
        if not IDLooksOK(Transport.ServerID) then begin
            ErrorString := 'An invalid serverID detected [' + Transport.ServerID + ']';
            debugln('ERROR - completed TestConnection but ServerID is invalid ['
                    + Transport.ServerID + ']');
            Result :=  SyncBadError;
        end;
end;

procedure TSync.DisplayNoteInfo(const meta : TNoteInfoList; const ListTitle : string);
var
    I : Integer;
    St : string;
begin
    debugln('-----------list dump for ' + ListTitle);
    for I := 0 to Meta.Count -1 do begin
        St := ' ' + inttostr(Meta.Items[i]^.Rev);
        while length(St) < 5 do St := St + ' ';
        // St := Meta.ActionName(Meta.Items[i]^.Action);
        debugln(Meta.Items[I]^.ID + St + Meta.ActionName(Meta.Items[i]^.Action)
            + Meta.Items[i]^.LastChange + '   ' + Meta.Items[I]^.Title);
    end;
end;


{ =====================   D A T A    C H E C K I N G    M E T H O D S  ============= }

function TSync.CheckUsingLCD(AssumeNoClash : boolean) : boolean;
var
    Index : integer;
    Count : integer = 0;
    Info : TSearchRec;
    PNote : PNoteInfo;
    LocLCD : string;        // The local note's last change date
begin
    { We declare a clash if both notes exist and LCDs are not identical.
      However, iff we have a local last sync date (LLSD) then if the
      earlier note pre-dates it, its not a clash. So, not a 'pure' LCD model,

    }
    if FindFirst(NotesDir + '*.note', faAnyFile, Info)=0 then begin
        try
        repeat
            inc(Count);
            PNote := NoteMetaData.FindID(copy(Info.Name, 1, 36));
            LocLCD := GetNoteLastChangeSt(NotesDir + Info.Name, ErrorString);
            // hmm, not checking for errors there .....
            if PNote <> nil then begin                      // ie, note exists on both sides
                if AssumeNoClash and (PNote^.LastChange = '')
                    then begin
                        if Debugmode then debugln('CheckUsingLCD exiting because if unresolved clash');
                        exit(false);                        // might be a clash, go fill out LCD in remote data
                    end;
                if PNote^.LastChange = LocLCD then          // its the same note
                    PNote^.Action := SyNothing
                else  begin
                    PNote^.Action := SyClash;             // Best we can do if last sync date not available.
                    if LocalLastSyncDateSt <> '' then begin          // We can override that iff we have a LLSD
                        if GetGMTFromStr(LocLCD) < LocalLastSyncDate then  PNote^.Action := SyDownload
                        else if  PNote^.LastChangeGMT < LocalLastSyncDate then PNote^.Action := SyUploadEdit;
                        if debugmode then
                            debugln('GMTimes - loc=' + FormatDateTime( 'yyyy-mm-dd hh:mm:ss', GetGMTFromStr(LocLCD))
                                     + '  rem=' + FormatDateTime( 'yyyy-mm-dd hh:mm:ss', PNote^.LastChangeGMT)
                                     + '  LLSD=' + FormatDateTime( 'yyyy-mm-dd hh:mm:ss', LocalLastSyncDate)
                                     + '  rem-st' + PNote^.LastChange);
                    end;
                end;
            end else begin                                  // this note is a new upload, add it to list.
                new(PNote);
                PNote^.ID := copy(Info.Name, 1, 36);
                PNote^.LastChange:=LocLCD;
                PNote^.Action:= SyUpLoadNew;                // Note, we may overrule that in CheckRemoteDeletes()
                NoteMetaData.Add(PNote);
            end;
        until FindNext(Info) <> 0;
        finally
            FindClose(Info);
        end;
    end;
    for Index := 0 to NoteMetaData.Count -1 do
        if NoteMetaData.Items[Index]^.Action = SyUnSet then
           NoteMetaData.Items[Index]^.Action := SyDownLoad;
    if DebugMode then
       Debugln('CheckUsingLCD checked against ' + inttostr(Count) + ' local notes');
    exit(True);
end;

procedure TSync.CheckRemoteDeletes();
var
    Index : integer;
    PNote : PNoteInfo;
    Count : integer = 0;
begin
    // Must find a created LocalMetaData but an empty one is normal.
    // Iterate over LocalMetaData looking for notes listed as prev synced
    // but are not listed in NoteMetaData. Or are listed as SyUploadNew !!
    // CheckUsingLCD puts all notes it finds locally but not in Remote as SyUploadNew
    // We'll add a entry (or change entry) in NoteMetaData for any we find.
    for Index := 0 to LocalMetaData.Count -1 do begin
        if not LocalMetaData.Items[Index]^.Deleted then begin
            PNote := NoteMetaData.FindID(LocalMetaData.Items[Index]^.ID);
            if PNote = nil then begin   // That is, we did not find it
                new(PNote);
                PNote^.ID:= LocalMetaData.Items[Index]^.ID;
                PNote^.Title := LocalMetaData.Items[Index]^.Title;                    // I think we know title, useful debug info here....
                PNote^.Action := SyDeleteLocal;                                       // Was deleted elsewhere, do same here.
                NoteMetaData.Add(PNote);
                inc(Count);
            end else begin
                if PNote^.Action = SyUploadNew then         // if it is mentioned in Local Man but Load decided it was '~New', its
                    PNote^.Action := SyDeleteLocal;         // really a note that was deleted remotely and should be deleted locally now
            end;
        end;
    end;
    if debugmode then debugln('CheckRemoteDeletes checked ' + inttostr(LocalMetaData.Count)
            + ' and found ' + inttostr(Count) + ' notes ');
end;

procedure TSync.CheckNewNotes();
var
    Info : TSearchRec;
    PNote : PNoteInfo;
    ID, CDate : string;
    Count : integer = 0;
    CountNew : integer = 0;
begin
    if FindFirst(NotesDir + '*.note', faAnyFile, Info)=0 then begin
        repeat
            ID := copy(Info.Name, 1, 36);
            inc(Count);
            //Debugln('Found [' + NotesDir+ Info.Name + ']');
            PNote := NoteMetaData.FindID(ID);
            if PNote = nil then begin
                if LocalNoteExists(ID, CDate, True) then begin
	                    new(PNote);
	                    Pnote^.ID:=ID;
	                    Pnote^.LastChange:=CDate;
                        // PNote^.Rev := self.;          // don't need, upload knows how to inc
	                    PNote^.Action:=SyUploadNew;
                        NoteMetaData.Add(PNote);
                        inc(CountNew);
				end else Debugln('Failed to find lastchangedate in ' + Info.Name);
			end;
			until FindNext(Info) <> 0;
        end;
    FindClose(Info);
    if debugMode then debugln('CheckNewNotes found ' + inttostr(Count) + ' notes in local dir and ' + inttostr(CountNew) + ' new ones.');
end;

    // Iterate over LocalMetaData looking for notes that have been deleted
    // locally and put them in RemoteMetaData to be deleted from the server.
procedure TSync.CheckLocalDeletes();
var
    I : integer;
    Count : integer = 0;
    PNote : PNoteInfo;
begin
    for I := 0 to LocalMetaData.Count -1 do begin
        if LocalMetaData.Items[i]^.Deleted then begin
            inc(Count);
            PNote := NoteMetaData.FindID(LocalMetaData.Items[i]^.ID);
            if PNote <> nil then
                PNote^.Action := SyDeleteRemote;
        end;
    end;
    if DebugMode then debugln('CheckLocalDeletes found ' + inttostr(Count) + ' deleted notes in local manifest');
end;

function TSync.CheckUsingRev() : boolean;
var
    I : integer;
    ID : string;    // to make it a bit easier to read souce
    PNote : PNoteInfo;
    LocCDate : string;
    LocChange, RemChange : boolean;
begin
    Result := True;
    for I := 0 to NoteMetaData.Count -1 do begin
        ID := NoteMetaData.Items[I]^.ID;
        if LocalNoteExists(ID, LocCDate) then begin
            LocalNoteExists(ID, LocCDate, True);
            LocChange := GetGMTFromStr(LocCDate) > LocalLastSyncDate;       // TDateTime is a float

            RemChange := NoteMetaData.Items[I]^.Rev > CurrRev;              // This is not valid for Tomdroid

            if LocChange and RemChange then
                NoteMetaData.Items[I]^.Action := SyClash
            else if LocChange then
                    NoteMetaData.Items[I]^.Action := SyUpLoadEdit
                else if RemChange then
                        NoteMetaData.Items[I]^.Action := SyDownLoad
                    else  NoteMetaData.Items[I]^.Action := SyNothing;
        end else begin      // OK, not here but maybe we deleted it previously ?
            Pnote := LocalMetaData.FindID(ID);
            if PNote <> Nil then begin
                if PNote^.Deleted then
                   NoteMetaData.Items[I]^.Action:=SyDeleteRemote;       // I have deleted that already.
            end else NoteMetaData.Items[I]^.Action:=SyDownload;         // its a new note from elsewhere
        end;
        if NoteMetaData.Items[I]^.Action = SyUnset then debugln('---- missed one -----');
        if NoteMetaData.Items[I]^.Action = SyUpLoadEdit then begin
            NoteMetaData.Items[I]^.LastChange := GetNoteLastChangeSt(NotesDir + ID + '.note', ErrorString);
            // debugln('=========== LCD is [' + NoteMetaData.Items[I]^.CreateDate + ']');
        end;
    end;
end;


{ ========================  N O T E   M O V E M E N T    M E T H O D S ================}

function TSync.DoDownloads() : boolean;
var
    I : integer;
begin
    Result := Transport.DownloadNotes(NoteMetaData);
	if Result = false then begin
       self.ErrorString:= Transport.ErrorString;
       debugln('ERROR - Download Notes reported ' + ErrorString);
	end;
    if not assigned( MarkNoteReadonlyProcedure) then begin // it should be set but not in the test rig !
           debugln('ERROR - MarkNoteReadOnly does not appear to be assigned (OK in Test_Rig)');
           exit;
       end;
    for I := 0 to NoteMetaData.Count -1 do
        if Notemetadata.Items[i]^.Action = SyDownload then
           MarkNoteReadonlyProcedure(NoteMetaData.Items[I]^.ID, False);
    if DebugMode then debugln('Downloaded notes.');
end;

function TSync.DoDeleteLocal() : boolean;
var
    I : integer;
begin
    for I := 0 to NoteMetaData.Count -1 do begin
        if NoteMetaData.Items[i]^.Action = SyDeleteLocal then begin
            if FileExists(NotesDir + NoteMetaData.Items[i]^.ID + '.note') then
                if CopyFile(NotesDir + NoteMetaData.Items[i]^.ID + '.note', NotesDir + PathDelim
                        + 'Backup' + Pathdelim + NoteMetaData.Items[i]^.ID + '.note') then
                    DeleteFile(NotesDir + NoteMetaData.Items[i]^.ID + '.note');
            MarkNoteReadonlyProcedure(NoteMetaData.Items[I]^.ID, True);
        end;
    end;
    result := true;
end;

function TSync.DoDeletes() : boolean;
var
    Index : integer;
begin
    for Index := 0 to NoteMetaData.Count - 1 do begin
        if NoteMetaData[Index]^.Action = SyDeleteRemote then begin
            if DebugMode then
               Debugln('Delete remote note : ' + NoteMetaData.Items[Index]^.ID);
            if not TestRun then begin
               if not Transport.DeleteNote(NoteMetaData.Items[Index]^.ID,
                            NoteMetaData.Items[Index]^.Rev) then Exit(False);
            end;
        end;
	end;
	Result := true;
end;

function TSync.DoUploads() : boolean;
var
    Uploads : TstringList;
    Index : integer;
begin
    if DebugMode then
        debugln('Doing uploads and Remote ServerRev is ' + inttostr(Transport.RemoteServerRev));
    try
        Uploads := TstringList.Create;
        for Index := 0 to NoteMetaData.Count -1 do begin
            if NoteMetaData.Items[Index]^.Action in [SyUploadEdit, SyUploadNew] then begin
               Uploads.Add(NoteMetaData.Items[Index]^.ID);
               NoteMetaData.Items[Index]^.Rev := Transport.RemoteServerRev + 1;
			end;
		end;
        if not TestRun then
           if not Transport.UploadNotes(Uploads) then begin
              ErrorString := Transport.ErrorString;
              exit(False);
		   end;
	finally
        Uploads.Free;
	end;
	Result := true;
end;

function TSync.WriteLocalManifest(const WriteOK, NewRev : boolean ): boolean;
{ We try and provide some recovery from a fail to write to remote repo. It should
  not happen but ... If WriteOk is false we write back local manifest that still
  mentions the previous deleted files and does not list locally new and changed
  files. Such files retain their thier previous rev numbers. Test !

  }
var
    OutFile: TextFile;
    Index : integer;
    IncRev : integer = 0;
begin
    if not IDLooksOK(Transport.ServerID) then exit(false);        // already checked but ....
    result := true;
    if WriteOK and NewRev then IncRev := 1 else IncRev := 0;
    AssignFile(OutFile, ConfigDir + ManPrefix + 'manifest.xml-local');  // ManPrefix is '' for most Modes.
    try
	        try
		        Rewrite(OutFile);
                writeln(OutFile, '<?xml version="1.0" encoding="utf-8"?>');
                writeln(Outfile, '<manifest xmlns="http://beatniksoftware.com/tomboy">');
                writeln(OutFile, '  <last-sync-date>' + GetLocalTime + '</last-sync-date>');
                write(OutFile, '  <last-sync-rev>"' + inttostr(Transport.RemoteServerRev + IncRev));
                writeln(OutFile, '"</last-sync-rev>');
                writeln(OutFile, '  <server-id>"' + Transport.ServerID + '"</server-id>');
                writeln(OutFile, '  <note-revisions>');
		        for Index := 0 to NoteMetaData.Count - 1 do begin
                    if NoteMetaData[Index]^.Action in [SyUploadNew, SyUpLoadEdit, SyDownLoad, SyNothing] then begin
                        if (not WriteOK) and (NoteMetaData[Index]^.Action = SyUpLoadNew) then continue;
                        write(Outfile, '    <note guid="' + NoteMetaData[Index]^.ID + '" latest-revision="');
                        write(OutFile, inttostr(NoteMetaData[Index]^.Rev));
                        writeln(Outfile, '" />');
					end;
				end;
                    writeln(OutFile, '  </note-revisions>'#10'  <note-deletions>');
                    writeln(OutFile, '  </note-deletions>'#10'</manifest>');
		    finally
	            CloseFile(OutFile);
		    end;
    except
      on E: EInOutError do begin
          Debugln('File handling error occurred. Details: ' + E.Message);
          exit(false);
	  end;
	end;
    // if to here, copy the file over top of existing local manifest
	if not TestRun then
       copyfile(ConfigDir + ManPrefix + 'manifest.xml-local', ConfigDir + ManPrefix + 'manifest.xml');
    if debugmode then
       debugln('Have written local manifest to ' + ConfigDir + ManPrefix + 'manifest.xml-local');
end;


function TSync.WriteRemoteManifest(out NewRev : boolean): boolean;
var
    OutFile: TextFile;
    Index : integer;
    NewRevString : string;
begin
    if not IDLooksOK(Transport.ServerID) then exit(false);        // already checked but ....
    result := true;
    NewRev := False;
    for Index := 0 to NoteMetaData.Count - 1 do begin
        if NoteMetaData[Index]^.Action in [SyUploadNew, SyUpLoadEdit, SyDeleteRemote] then begin
            NewRev := True;
            break;                  // one is enough, we need a new manifest file !
		end;
    end;
    if Not NewRev then exit(true);      // exit cos no need for new Man, ret true cos no file error,
    NewRevString := inttostr(Transport.RemoteServerRev + 1);
    AssignFile(OutFile, ConfigDir + 'manifest.xml-remote');
    try
	    try
		    Rewrite(OutFile);
	        writeln(OutFile, '<?xml version="1.0" encoding="utf-8"?>');
            write(OutFile, '<sync revision="' + NewRevString);
            writeln(OutFile, '" server-id="' + Transport.ServerID + '">');
	        for Index := 0 to NoteMetaData.Count - 1 do begin
                if NoteMetaData[Index]^.Action in [SyUploadNew, SyUpLoadEdit, SyDownLoad, SyNothing] then begin
	                write(OutFile, '  <note id="' + NoteMetaData.Items[Index]^.ID + '" rev="');
                    if NoteMetaData[Index]^.Action in [SyUploadNew, SyUpLoadEdit] then
	                    write(OutFile, NewRevString + '"')
	                else write(OutFile, inttostr(NoteMetaData.Items[Index]^.Rev) + '"');
                    if NoteMetaData.Items[Index]^.LastChange = '' then
                       writeln(OutFile, ' />')
                    else writeln(OutFile, ' last-change-date="'
                            + NoteMetaData.Items[Index]^.LastChange + '" />');
				end;
			end;
            writeln(OutFile, '</sync>');
        except
          on E: EInOutError do begin
              Debugln('File handling error occurred. Details: ' + E.Message);
              exit(false);      // file error !
    	  end;
    	end;
	finally
        CloseFile(OutFile);
	end;
        // do a safe version of this -
    if not TestRun then
           result := Transport.DoRemoteManifest(ConfigDir + 'manifest.xml-remote');
    if debugmode then
       debugln('Have written remote manifest to ' + ConfigDir + ManPrefix + 'manifest.xml-remote');
end;


{ =================  S T A R T   U P   M E T H O D S ============== }


function TSync.SetTransport(Mode: TSyncTransport) : TSyncAvailable;
begin
    TransportMode := Mode;
    NotesDir := AppendPathDelim(NotesDir);
    ConfigDir := AppendPathDelim(ConfigDir);
    ErrorString := '';
    FreeAndNil(Transport);
    case Mode of
        SyncFile : begin
                SyncAddress := AppendPathDelim(SyncAddress);
                Transport := TFileSync.Create;
	        end;
        SyncNextRuby : begin
                Transport := TNetSync.Create;
                // SyncAddress := AppendPathDelim(SyncAddress);       ??
            end;
        SyncAndroid : begin
                debugln('Oh boy ! We have called the android line !');
                Transport := TAndSync.Create;
            end;
    end;
    Transport.Password := Password;
    Transport.NotesDir := NotesDir;
    Transport.DebugMode := DebugMode;
    if TransportMode = SyncAndroid then begin
        ConfigDir := ConfigDir + 'android' + PathDelim;
        ForceDirectory(ConfigDir);
    end;
    Transport.ConfigDir := ConfigDir;
    Transport.RemoteAddress:= SyncAddress;
    Result := Transport.TestTransportEarly(ManPrefix);          // important Tomdroid, not Filesync
    ErrorString := Transport.ErrorString;
    if DebugMode then begin
        debugln('Remote address is ' + SyncAddress);
        debugln('Local Config ' + ConfigDir);
        debugln('Notes dir ' + NotesDir);
	end;
end;

function TSync.LoadRepoData(ForceLCD : boolean): boolean;
begin
    Result := True;
    FreeAndNil(NoteMetaData);
    NoteMetaData := TNoteInfoList.Create;
    case RepoAction of
        RepoUse : Result := Transport.GetNewNotes(NoteMetaData, False);
        RepoJoin : Result := Transport.GetNewNotes(NoteMetaData, ForceLCD);
    end;
    if DebugMode then begin
        debugln('LoadRepoData found ' + inttostr(NoteMetaData.Count) + ' remote notes');
        DisplayNoteInfo(NoteMetaData, 'NoteMetaData just after Loading');
    end;
    // We do not load remote metadata when creating a new repo !
end;

                        { ---------- The Lets Do it Function ------------- }

function TSync.StartSync(): boolean;
var
    NewRev : boolean;
    // Tick1, Tick2, Tick3, Tick4 : Dword;
begin
    Result := True;
    // TestRun := True;
    if not LoadRepoData(False) then exit(False);     // don't get LCD until we know we need it.
    case RepoAction of
        RepoUse : begin
                    if TransportMode = SyncAndroid then CheckUsingLCD(False) else CheckUsingRev();
                    CheckRemoteDeletes();
                    CheckLocalDeletes();
                end;
        RepoJoin : if not CheckUsingLCD(True) then begin    // at least 1 possible clash
                 LoadRepoData(True);                        // start again, getting LCD this time
                 CheckUsingLCD(False);
            end;
        RepoNew : begin
                freeandNil(NoteMetaData);
                NoteMetaData := TNoteInfoList.Create;
            end
    end;
    CheckNewNotes();
    CheckMetaData();
    if not TestRun then
       ProcessClashes();
    if DebugMode then DisplayNoteInfo(NoteMetaData, 'NoteMetaData');
    if TestRun then exit();
    // ====================== Set an exit here to do no-write tests
    if DoDownLoads() then           // DoDownloads() will tell us what troubled it.
        if WriteRemoteManifest(NewRev) then
            if DoDeletes() then
                if DoUploads() then
                   if DoDeleteLocal() then
	                    if not WriteLocalManifest(true, NewRev) then
                              WriteLocalManifest(false, false);   // write a recovery local manifest. Downloads only noted.
    Result := True;
end;

function TSync.ReadLocalManifest() : boolean;
var
    Doc : TXMLDocument;
    NodeList : TDOMNodeList;
    Node : TDOMNode;
    j : integer;
    NoteInfoP : PNoteInfo;
    RevStr : string;
begin
    Result := true;
    ErrorString := '';
    freeandNil(LocalMetaData);
    LocalMetaData := TNoteInfoList.Create;
    if not FileExists(ConfigDir + ManPrefix + 'manifest.xml') then begin
        LocalLastSyncDateSt := '';
        CurrRev := 0;
        exit(True);                 // Its not an error, just never synced before
    end;
    if DebugMode then debugln('Reading local mainfest ' + ConfigDir + ManPrefix + 'manifest.xml');
    try
    	try
    		ReadXMLFile(Doc, ConfigDir + ManPrefix + 'manifest.xml');
            Node := Doc.DocumentElement.FindNode('last-sync-date');
            if assigned(Node) then
                LocalLastSyncDateSt := Node.FirstChild.NodeValue
            else begin
                LocalLastSyncDateSt := '';
                debugln('ERROR, cannot find LSD in ' + ConfigDir + 'manifest.xml');
            end;
            Node := Doc.DocumentElement.FindNode('server-id');
            LocalLastSyncID := Node.FirstChild.NodeValue;
            if LocalLastSyncID[1] = '"' then
               LocalLastSyncID := copy(LocalLastSyncID, 2, 36);
            if length(LocalLastSyncID) <> 36 then begin
                ErrorString := 'Local manifest contains an invalid serverID';
                debugln('ERROR - local manifest contains an invalid serverID ');
                debugln('Maybe you should delete it and rejoin the Repo. ?');
                exit(false);
            end;
            Node := Doc.DocumentElement.FindNode('last-sync-rev');
            try
                RevStr := Node.FirstChild.NodeValue;
                if RevStr[1] = '"' then
                   Revstr := copy(revStr, 2, length(RevStr) - 2);
        		CurrRev := strtoint(RevStr);
			except
                    on EConvertError do                         // just a plain bad string
                        ErrorString := 'Error converting Local Rev Version ' + RevStr;
					on EObjectCheck do                         // mac does this
                        ErrorString := 'Error in local mainfest, check RevNo';
                    on EAccessViolation do                  	// Lin does this
                        ErrorString := 'Error in local mainfest, check RevNo';
            end;
            if ErrorString <> '' then begin
                CurrRev := 0;
                LocalLastSyncDateSt := '';
                exit(False);
			end;
			NodeList := Doc.DocumentElement.FindNode('note-revisions').ChildNodes;
            if assigned(NodeList) then
               for j := 0 to NodeList.Count-1 do begin
                   new(NoteInfoP);
                   NoteInfoP^.ID := NodeList.Item[j].Attributes.GetNamedItem('guid').NodeValue;
                   NoteInfoP^.Rev := strtoint(NodeList.Item[j].Attributes.GetNamedItem('latest-revision').NodeValue);
                   NoteInfoP^.Deleted := False;
                   LocalMetaData.Add(NoteInfoP);
			   end;
            NodeList := Doc.DocumentElement.FindNode('note-deletions').ChildNodes;
            if assigned(NodeList) then
               for j := 0 to NodeList.Count-1 do begin
                   new(NoteInfoP);
                   NoteInfoP^.ID := NodeList.Item[j].Attributes.GetNamedItem('guid').NodeValue;
                   NoteInfoP^.Title := NodeList.Item[j].Attributes.GetNamedItem('title').NodeValue;
                   NoteInfoP^.Deleted := True;
                   LocalMetaData.Add(NoteInfoP);
   			   end;
		finally
            Doc.Free;
		end;
	except
      on EAccessViolation do begin         // probably means we did not find an expected attribute
              ErrorString := 'Error in local mainfest';
              CurrRev := 0;
              LocalLastSyncDateSt := '';
              Result := false;
          end;
	end;
    if Debugmode then DisplayNoteInfo(LocalMetaData, 'LocalMetaData');
end;

procedure TSync.FSetConfigDir(Dir: string);
begin
        FConfigDir := AppendPathDelim(Dir);
        if DirectoryExists(FConfigDir) then begin
           if Not DirectoryIsWritable(FConfigDir) then
              self.ErrorString:= 'Cannot write to config dir';
		end else ErrorString := 'Config dir does not exist';
end;

procedure TSync.FSetNotesDir(Dir: string);
begin
        FNotesDir := AppendPathDelim(Dir);
end;

end.

