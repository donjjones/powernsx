#Powershell NSX module
#Nick Bradford
#nbradford@vmware.com
#Version 1.0 RC 1



#Copyright © 2015 VMware, Inc. All Rights Reserved.

#Permission is hereby granted, free of charge, to any person obtaining a copy of
#this software and associated documentation files (the "Software"), to deal in 
#the Software without restriction, including without limitation the rights to 
#use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies 
#of the Software, and to permit persons to whom the Software is furnished to do 
#so, subject to the following conditions:

#The above copyright notice and this permission notice shall be included in all 
#copies or substantial portions of the Software.

#THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR 
#IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, 
#FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE 
#AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER 
#LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, 
#OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE 
#SOFTWARE.

### Note
#This powershell module should be considered entirely experimental and dangerous
#and is likely to kill babies, cause war and pestilence and permanently block all 
#your toilets.  Seriously - It's still in development,  not tested beyond lab 
#scenarios, and its recommended you dont use it for any production environment 
#without testing extensively!


###
# To Do
#
# - Get Edges on LS -> needs get-nsxedge to accept LS as input object
# - Set/New LR interface functions returning xmldoc, not element.  Check edge interface output as well.
# - Need to check for PowerCLI we now pretty much require it - which is snapin or module...dang it...
# - Update Edge (LB? ) validation cmdlets with edgeId

#Requires -Version 3.0


set-strictmode -version Latest

## Custom classes

if ( -not ("TrustAllCertsPolicy" -as [type])) {

    add-type @"
    using System.Net;
    using System.Security.Cryptography.X509Certificates;
    public class TrustAllCertsPolicy : ICertificatePolicy {
        public bool CheckValidationResult(
            ServicePoint srvPoint, X509Certificate certificate,
            WebRequest request, int certificateProblem) {
            return true;
        }
    }
"@

}

########
########
# Private functions

function Invoke-NsxRestMethod {

    #Internal method to construct the REST call headers including auth as expected by NSX.
    #Accepts either a connection object as produced by connect-nsxserver or explicit
    #parameters.

    [CmdletBinding(DefaultParameterSetName="ConnectionObj")]
  
    param (
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [System.Management.Automation.PSCredential]$cred,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [string]$server,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [int]$port,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [string]$protocol,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [bool]$ValidateCertificate,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
        [Parameter (ParameterSetName="ConnectionObj")]
            [string]$method,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
        [Parameter (ParameterSetName="ConnectionObj")]
            [string]$URI,
        [Parameter (Mandatory=$false,ParameterSetName="Parameter")]
        [Parameter (ParameterSetName="ConnectionObj")]
            [string]$body = "",
        [Parameter (Mandatory=$false,ParameterSetName="ConnectionObj")]
            [psObject]$connection,
        [Parameter (Mandatory=$false,ParameterSetName="ConnectionObj")]
            [System.Collections.Hashtable]$extraheader   
    )

    Write-Debug "$($MyInvocation.MyCommand.Name) : ParameterSetName : $($pscmdlet.ParameterSetName)"

    if ($pscmdlet.ParameterSetName -eq "Parameter") {
        if ( -not $ValidateCertificate) { 
            #allow untrusted certificate presented by the remote system to be accepted 
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }
    }
    else {

        #ensure we were either called with a connection or there is a defaultConnection (user has 
        #called connect-nsxserver) 
        #Little Grr - $connection is a defined variable with no value so we cant use test-path
        if ( $connection -eq $null) {
            
            #Now we need to assume that defaultnsxconnection does not exist...
            if ( -not (test-path variable:global:DefaultNSXConnection) ) { 
                throw "Not connected.  Connect to NSX manager with Connect-NsxServer first." 
            }
            else { 
                Write-Debug "$($MyInvocation.MyCommand.Name) : Using default connection"
                $connection = $DefaultNSXConnection
            }       
        }

        
        if ( -not $connection.ValidateCertificate ) { 
            #allow untrusted certificate presented by the remote system to be accepted 
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }

        $cred = $connection.credential
        $server = $connection.Server
        $port = $connection.Port
        $protocol = $connection.Protocol

    }

    $headerDictionary = @{}
    $base64cred = [system.convert]::ToBase64String(
        [system.text.encoding]::ASCII.Getbytes(
            "$($cred.GetNetworkCredential().username):$($cred.GetNetworkCredential().password)"
        )
    )
    $headerDictionary.add("Authorization", "Basic $Base64cred")

    if ( $extraHeader ) {
        foreach ($header in $extraHeader.GetEnumerator()) {
            write-debug "$($MyInvocation.MyCommand.Name) : Adding extra header $($header.Key ) : $($header.Value)"
            $headerDictionary.add($header.Key, $header.Value)
        }
    }
    $FullURI = "$($protocol)://$($server):$($Port)$($URI)"
    write-debug "$($MyInvocation.MyCommand.Name) : Method: $method, URI: $FullURI, Body: `n$($body | Format-Xml)"
    #do rest call
    
    try { 
        if (( $method -eq "put" ) -or ( $method -eq "post" )) { 
            $response = invoke-restmethod -method $method -headers $headerDictionary -ContentType "application/xml" -uri $FullURI -body $body
        } else {
            $response = invoke-restmethod -method $method -headers $headerDictionary -ContentType "application/xml" -uri $FullURI
        }
    }
    catch {
        
        #Get response from the exception
        $response = $_.exception.response
        if ($response) {  
            $responseStream = $_.exception.response.GetResponseStream()
            $reader = New-Object system.io.streamreader($responseStream)
            $responseBody = $reader.readtoend()
            $ErrorString = "invoke-nsxrestmethod : Exception occured calling invoke-restmethod. $($response.StatusCode.value__) : $($response.StatusDescription) : Response Body: $($responseBody)"
            throw $ErrorString
        }
        else { 
            throw $_ 
        } 
        

    }
    switch ( $response ) {
        { $_ -is [xml] } { write-debug "$($MyInvocation.MyCommand.Name) : Response: `n$($response.outerxml | Format-Xml)" } 
        { $_ -is [System.String] } { write-debug "$($MyInvocation.MyCommand.Name) : Response: $($response)" }
        default { write-debug "$($MyInvocation.MyCommand.Name) : Response type unknown" }

    }

    #Workaround for bug in invoke-restmethod where it doesnt complete the tcp session close to our server after certain calls. 
    #We end up with connectionlimit number of tcp sessions in close_wait and future calls die with a timeout failure.
    #So, we are getting and killing active sessions after each call.  Not sure of performance impact as yet - to test
    #and probably rewrite over time to use invoke-webrequest for all calls... PiTA!!!! :|

    $ServicePoint = [System.Net.ServicePointManager]::FindServicePoint($FullURI)
    $ServicePoint.CloseConnectionGroup("") | out-null
    write-debug "$($MyInvocation.MyCommand.Name) : Closing connections to $FullURI."

    #Return
    $response

}
Export-ModuleMember -function Invoke-NsxRestMethod

function Invoke-NsxWebRequest {

    #Internal method to construct the REST call headers etc
    #Alternative to Invoke-NsxRestMethod that enables retrieval of response headers
    #as the NSX API is not overly consistent when it comes to methods of returning 
    #information to the caller :|.  Used by edge cmdlets like new/update esg and logicalrouter.

    [CmdletBinding(DefaultParameterSetName="ConnectionObj")]
  
    param (
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [System.Management.Automation.PSCredential]$cred,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [string]$server,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [int]$port,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [string]$protocol,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
            [bool]$ValidateCertificate,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
        [Parameter (ParameterSetName="ConnectionObj")]
            [string]$method,
        [Parameter (Mandatory=$true,ParameterSetName="Parameter")]
        [Parameter (ParameterSetName="ConnectionObj")]
            [string]$URI,
        [Parameter (Mandatory=$false,ParameterSetName="Parameter")]
        [Parameter (ParameterSetName="ConnectionObj")]
            [string]$body = "",
        [Parameter (Mandatory=$false,ParameterSetName="ConnectionObj")]
            [psObject]$connection,
        [Parameter (Mandatory=$false,ParameterSetName="ConnectionObj")]
            [System.Collections.Hashtable]$extraheader   
    )

    Write-Debug "$($MyInvocation.MyCommand.Name) : ParameterSetName : $($pscmdlet.ParameterSetName)"

    if ($pscmdlet.ParameterSetName -eq "Parameter") {
        if ( -not $ValidateCertificate) { 
            #allow untrusted certificate presented by the remote system to be accepted 
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }
    }
    else {

        #ensure we were either called with a connection or there is a defaultConnection (user has 
        #called connect-nsxserver) 
        #Little Grr - $connection is a defined variable with no value so we cant use test-path
        if ( $connection -eq $null) {
            
            #Now we need to assume that defaultnsxconnection does not exist...
            if ( -not (test-path variable:global:DefaultNSXConnection) ) { 
                throw "Not connected.  Connect to NSX manager with Connect-NsxServer first." 
            }
            else { 
                Write-Debug "$($MyInvocation.MyCommand.Name) : Using default connection"
                $connection = $DefaultNSXConnection
            }       
        }

        
        if ( -not $connection.ValidateCertificate ) { 
            #allow untrusted certificate presented by the remote system to be accepted 
            [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
        }

        $cred = $connection.credential
        $server = $connection.Server
        $port = $connection.Port
        $protocol = $connection.Protocol

    }

    $headerDictionary = @{}
    $base64cred = [system.convert]::ToBase64String(
        [system.text.encoding]::ASCII.Getbytes(
            "$($cred.GetNetworkCredential().username):$($cred.GetNetworkCredential().password)"
        )
    )
    $headerDictionary.add("Authorization", "Basic $Base64cred")

    if ( $extraHeader ) {
        foreach ($header in $extraHeader.GetEnumerator()) {
            write-debug "$($MyInvocation.MyCommand.Name) : Adding extra header $($header.Key ) : $($header.Value)"
            $headerDictionary.add($header.Key, $header.Value)
        }
    }
    $FullURI = "$($protocol)://$($server):$($Port)$($URI)"
    write-debug "$($MyInvocation.MyCommand.Name) : Method: $method, URI: $FullURI, Body: `n$($body | Format-Xml)"
    #do rest call
    
    try { 
        if (( $method -eq "put" ) -or ( $method -eq "post" )) { 
            $response = invoke-webrequest -method $method -headers $headerDictionary -ContentType "application/xml" -uri $FullURI -body $body
        } else {
            $response = invoke-webrequest -method $method -headers $headerDictionary -ContentType "application/xml" -uri $FullURI
        }
    }
    catch {
        
        #Get response from the exception
        $response = $_.exception.response
        if ($response) {  
            $responseStream = $_.exception.response.GetResponseStream()
            $reader = New-Object system.io.streamreader($responseStream)
            $responseBody = $reader.readtoend()
            $ErrorString = "invoke-nsxwebrequest : Exception occured calling invoke-restmethod. $($response.StatusCode) : $($response.StatusDescription) : Response Body: $($responseBody)"
            throw $ErrorString
        }
        else { 
            throw $_ 
        } 
        

    }
    switch ( $response.content ) {
        { $_ -is [System.String] } { write-debug "$($MyInvocation.MyCommand.Name) : Response Body: $($response.content), Response Headers: $($response.Headers)" }
        default { write-debug "$($MyInvocation.MyCommand.Name) : Response type unknown" }

    }
    $response
}

Export-ModuleMember -Function Invoke-NsxWebRequest

function Add-XmlElement {

    #Internal function used to simplify the exercise of adding XML text Nodes.
    param ( 

        [System.XML.XMLElement]$xmlRoot,
        [String]$xmlElementName,
        [String]$xmlElementText
    )

    #Create an Element and append it to the root
    [System.XML.XMLElement]$xmlNode = $xmlRoot.OwnerDocument.CreateElement($xmlElementName)
    [System.XML.XMLNode]$xmlText = $xmlRoot.OwnerDocument.CreateTextNode($xmlElementText)
    $xmlNode.AppendChild($xmlText) | out-null
    $xmlRoot.AppendChild($xmlNode) | out-null
}
Export-ModuleMember -function Add-XmlElement

function Get-EasterEgg {

$OhCaptainMyCaptain = @"                                                                                 
                                                                                 
                                                                                 
                                                                                 
                                                                                 
                                                                                 
                                                                                 
                                                                                 
                                                                                 
                                         `                                       
                                 `;;###',.`                                      
                               `'#++##@#+#+@;'`                                  
                             `;#++++@#++####+@#+'                                
                             +##+#+###+++@###@#@#;..                             
                            :#+#'++##+''+##@+###@@#:                             
                           ,'+''+##++#+++##+######'+:                            
                         `'+'+;''#'##++'+##+#@@@+#+'#`                           
                         +;;+;#'#'++@@##@'+#@#@#@##:'+                           
                        ;';:+#++++'#+####@#'+#@@@@+#++@                          
                        ;++@@+#'++@@##+###+++#####;+###.                         
                       .+++@#+#'+##+###@@#+';;'++###,'++`                        
                       +#'##+#+##@+'+@##@+;:::;;'+####@+;                        
                       +;+@'@+@###+''+++':::,,,:;'+#+#@#+                        
                      `#'@'@;#@##''';;;;:,,,,,,,:;'+#+#@@`                       
                       +#;@+'@#+#+';;;;::,,,,,,,,,:;+###@,                       
                      +#+;;;'+,++''';;:::,,,,,,.,,,,;+#@@:                       
                      +'#;';',.::'';;:;;:,,,,,,,..,,,;+##;                       
                      #+'#'';::::;;;;::::,:,,,,,,,,,,,;:#@                       
                      ###'+''::,:;;;::::::,,,,,.,,.,,,;;+;                       
                     `;#+''+'::::::;;;:::,,,,,,,,,,,,::#+                        
                     .;+#;#+::;:,,''''''':,,::::::::,,:#'` `                     
                     :'+'##',:;,'++####+#+::;+'#+''';::@+                        
                     ;.;++#:,::+@#@@###+++::'#####+#++:@#+                       
                     ;,;;+'.,'+####+#+++'';:;'+####+++:'+'                       
                     '+';#;,:+++####@##+++;::;+##@+'';;;#;                       
                     ;+''#,,;+++@+#'@,##++;,:'+##+:#+:,;',                       
                     ;;`';,,;+++++'+;;++++;.,:+'#+:'::,:;:                       
                     ,,'+.:::'''+++''''+++;,,::;'';:,,:;;;                       
                     :'';,::::;;'''''''+++;,,,::;;:::,,:;;                       
                     :'+:::::::;;;;;;;'''+':,,,,:,,,,,,;,:                       
                     ::#':::::;;:;::;;''++':,,,,,,,,,,,;:;                       
                     :;;';;::;:;:::::;'+++':,,,,,,,,,,:;:'                       
                     ::,;:;:;;;;;:::;;'+++;:.,:,,,,,,,:;:'                       
                     ,,.+:;;;;''';;:;'+''';,.,:;:,,,,::;:'                       
                      ::+:;;;+''';;;;'+''';:.,,;;:,,,::;:'                       
                      ;'':;:;++'''';''++++'';;;,;;::,::;:;                       
                         :;;;+++''''''++##+''+,,,:;::::;;                        
                         :;;;+++''''+++#++++;::,,,;:::;'                         
                         :;;;'+''''''++++''':,:::::::;;;                         
                         :;;;++'''''+'''':::,,:;;;::::;:                         
                          ;;;+++'''+##++++''++';+';::;;                          
                          ;';+++'''''+++'+#+';':;';:;;;                          
                          `'''++'''''''+';:::::,,:;;;;,                          
                          .;''++''''''+''';;;::,::;;;'                           
                         .:,''+++''''''+++++';:::;;;;                            
                         `#,;'''+++'''''''''::::;;;;                             
                        .`#,:'+''++''';;;:;;:::;:;;',                            
                         `@,:'++''+++';;;:::::::';++.`                           
                       . `@,;'+'+''+++';;;;;::;'';#+:`                           
                        ``#':;++'+''++++'++'';''':++;`,                          
                      .```:+;'''''''''++++++++'';:++;.`                          
                       ```.@'''''''''''''''''+';::++;,`:                         
                     ,````.#+'''''''''''''''';;;:;+';,```                        
                    . ````.,#+'''''''''''';;;:;::;#';:``.`:                      
                  .`.````...#+'''''''''';;;:;;;::++;::``````..                   
                .`..``````..,#'''''''';'';;;:;:::+'::,`````````:                 
              .``.,,``````...'#''''''';'';;;:::::+'::,````.``````,.              
           `.`..`.,.``````.`.,#+'';;;';';;;::::::+'::,`````.````````:            
         ,`````:.`. ````......:#';;;;;;;;;;:::::;,':::````````````..``:          
       ,```,`,:,...`````..`....++;;;;;;;;;;:::::+`:,:,+':`.`.`````.....`,        
     :``....:,:,..,`````........'+;;;;;;;;;:::,;`.,,,.'';..````````.`.....,      
   :``....:,.,::,.,`````.........,.';;;;;;:::::``:,,.'';;,..,.``````...``...`    
 .``.`.,:..,.,::,,,`````......`.,.,..````..`````.:,,';;;;:,.`:.``````.````.`.,   
,``,.```....,,:,,,:`````..````,':::....````````...;;;;;;;;:.``:.`````````.``..   
.`....````...,,,,,:````....`.';::::;.......`````:,:::::;;;;,```:`````````.``..;  
........,......,,,,````..`.;;;;,:;:,:,..```````.`,,,,:::::;:.`````````````.```.  
``.....,.,,,..,,,,.```` `,;,,::;.,,:::..``````......,,,,,,,:.`````````````..`.`. 
```.......,.,,,,,,.`` .:;,,,,,:::;..,::``````..,,..........,.`````````````...`., 
```.........,,,:::..,,,:::,,,,,,::::,,:,````..,:,`..``````...`````````````..```. 
.```........,,,:::,,,,,,,,,,,,,,,,,:;,,:`.``...,,.`````````````````````````````.:
:,.``.....,,,,,:::,,,,,,,,,,,,,,,,,,,:;:,:```,..`````````````````````````````````
::,.`.....,,,,,:::,,,,,,,,.,,,,,,,,,,,.,;:,,....````````````````````````````````,
.::,..````..,,,:::,,,,,,,,....,...,,,,,,.`::,..````````````````````````````````.:
.,::...`````.,,,,,,,,.,,..............,,,,``;.`````````````````````````````.````,
,,,::..```````..,,,....................`....,.`````````````````````````````````..
`,,::,...`...```....................``````.,,.``````````````````````````````````,
..,:::.........``.`...............````````.,.```````````````````````````````````,
..,,::,..````....................``````.``.:``````````````````````````````````..,
"@

    $OhCaptainMyCaptain
}
Export-ModuleMember -function Get-EasterEgg

########
########
# Validation Functions

Function Validate-LogicalSwitchOrDistributedPortGroup {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )      

    if (-not (
        ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl] ) -or
        ($argument -is [VMware.VimAutomation.Vds.Impl.VDObjectImpl] ) -or
        ($argument -is [System.Xml.XmlElement] )))
    { 
        throw "Must specify a distributed port group or a logical switch" 
    } 
    else {

        #Do we Look like XML describing a Logical Switch
        if ($argument -is [System.Xml.XmlElement] ) {
            if ( -not ( $argument | get-member -name objectId -Membertype Properties)) { 
                throw "Object specified does not contain an objectId property.  Specify a Distributed PortGroup or Logical Switch object."
            }
            if ( -not ( $argument | get-member -name objectTypeName -Membertype Properties)) { 
                throw "Object specified does not contain a type property.  Specify a Distributed PortGroup or Logical Switch object."
            }
            if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
                throw "Object specified does not contain a name property.  Specify a Distributed PortGroup or Logical Switch object."
            }
            switch ($argument.objectTypeName) {
                "VirtualWire" { }
                default { throw "Object specified is not a supported type.  Specify a Distributed PortGroup or Logical Switch object." }
            }
        }
        else { 
            #Its a VDS type - no further Checking
        }   
    }
    $true
}

Function Validate-LogicalSwitch {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )      

    if (-not ($argument -is [System.Xml.XmlElement] ))
    { 
        throw "Must specify a logical switch" 
    } 
    else {

        #Do we Look like XML describing a Logical Switch
        
        if ( -not ( $argument | get-member -name objectId -Membertype Properties)) { 
            throw "Object specified does not contain an objectId property.  Specify a Logical Switch object."
        }
        if ( -not ( $argument | get-member -name objectTypeName -Membertype Properties)) { 
            throw "Object specified does not contain a type property.  Specify a Logical Switch object."
        }
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "Object specified does not contain a name property.  Specify a Logical Switch object."
        }
        switch ($argument.objectTypeName) {
            "VirtualWire" { }
            default { throw "Object specified is not a supported type.  Specify a Logical Switch object." }
        }   
    }
    $true
}

Function Validate-LogicalRouterInterfaceSpec {

    Param (

        [Parameter (Mandatory=$true)]
        [object]$argument

    )     

    #temporary - need to script proper validation of a single valid NIC config for DLR (Edge and DLR have different specs :())
    if ( -not $argument ) { 
        throw "Specify at least one interface configuration as produced by New-NsxLogicalRouterInterfaceSpec.  Pass a collection of interface objects to configure more than one interface"
    }
    $true
}

Function Validate-EdgeInterfaceSpec {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #temporary - need to script proper validation of a single valid NIC config for DLR (Edge and DLR have different specs :())
    if ( -not $argument ) { 
        throw "Specify at least one interface configuration as produced by New-NsxLogicalRouterInterfaceSpec.  Pass a collection of interface objects to configure more than one interface"
    }
    $true
}

Function Validate-LogicalRouter {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if we are an XML element
    if ($argument -is [System.Xml.XmlElement] ) {
        if ( $argument | get-member -name edgeSummary -memberType Properties) { 
            if ( -not ( $argument.edgeSummary | get-member -name objectId -Membertype Properties)) { 
                throw "XML Element specified does not contain an edgesummary.objectId property.  Specify a valid Logical Router Object"
            }
            if ( -not ( $argument.edgeSummary | get-member -name objectTypeName -Membertype Properties)) { 
                throw "XML Element specified does not contain an edgesummary.ObjectTypeName property.  Specify a valid Logical Router Object"
            }
            if ( -not ( $argument.edgeSummary | get-member -name name -Membertype Properties)) { 
                throw "XML Element specified does not contain an edgesummary.name property.  Specify a valid Logical Router Object"
            }
            if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
                throw "XML Element specified does not contain a type property.  Specify a valid Logical Router Object"
            }
            if ($argument.edgeSummary.objectTypeName -ne "Edge" ) { 
                throw "Specified value is not a supported type.  Specify a valid Logical Router Object." 
            }
            if ($argument.type -ne "distributedRouter" ) { 
                throw "Specified value is not a supported type.  Specify a valid Logical Router Object." 
            }
            $true
        }
        else {
            throw "Specify a valid Logical Router Object"
        }   
    }
    else {
        throw "Specify a valid Logical Router Object"
    }
}

Function Validate-Edge {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if we are an XML element
    if ($argument -is [System.Xml.XmlElement] ) {
        if ( $argument | get-member -name edgeSummary -memberType Properties) { 
            if ( -not ( $argument.edgeSummary | get-member -name objectId -Membertype Properties)) { 
                throw "XML Element specified does not contain an edgesummary.objectId property.  Specify an NSX Edge Services Gateway object"
            }
            if ( -not ( $argument.edgeSummary | get-member -name objectTypeName -Membertype Properties)) { 
                throw "XML Element specified does not contain an edgesummary.ObjectTypeName property.  Specify an NSX Edge Services Gateway object"
            }
            if ( -not ( $argument.edgeSummary | get-member -name name -Membertype Properties)) { 
                throw "XML Element specified does not contain an edgesummary.name property.  Specify an NSX Edge Services Gateway object"
            }
            if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
                throw "XML Element specified does not contain a type property.  Specify an NSX Edge Services Gateway object"
            }
            if ($argument.edgeSummary.objectTypeName -ne "Edge" ) { 
                throw "Specified value is not a supported type.  Specify an NSX Edge Services Gateway object." 
            }
            if ($argument.type -ne "gatewayServices" ) { 
                throw "Specified value is not a supported type.  Specify an NSX Edge Services Gateway object." 
            }
            $true
        }
        else {
            throw "Specify a valid Edge Services Gateway Object"
        }   
    }
    else {
        throw "Specify a valid Edge Services Gateway Object"
    }
}

Function Validate-EdgeRouting {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an Edge routing element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name routingGlobalConfig -Membertype Properties)) { 
            throw "XML Element specified does not contain a routingGlobalConfig property."
        }
        if ( -not ( $argument | get-member -name enabled -Membertype Properties)) { 
            throw "XML Element specified does not contain an enabled property."
        }
        if ( -not ( $argument | get-member -name version -Membertype Properties)) { 
            throw "XML Element specified does not contain a version property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge Routing object."
    }
}

Function Validate-EdgeStaticRoute {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an Edge routing element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
            throw "XML Element specified does not contain a type property."
        }
        if ( -not ( $argument | get-member -name network -Membertype Properties)) { 
            throw "XML Element specified does not contain a network property."
        }
        if ( -not ( $argument | get-member -name nextHop -Membertype Properties)) { 
            throw "XML Element specified does not contain a nextHop property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge Static Route object."
    }
}

Function Validate-EdgeBgpNeighbour {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an Edge routing element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property."
        }
        if ( -not ( $argument | get-member -name remoteAS -Membertype Properties)) { 
            throw "XML Element specified does not contain a remoteAS property."
        }
        if ( -not ( $argument | get-member -name weight -Membertype Properties)) { 
            throw "XML Element specified does not contain a weight property."
        }
        if ( -not ( $argument | get-member -name holdDownTimer -Membertype Properties)) { 
            throw "XML Element specified does not contain a holdDownTimer property."
        }
        if ( -not ( $argument | get-member -name keepAliveTimer -Membertype Properties)) { 
            throw "XML Element specified does not contain a keepAliveTimer property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge BGP Neighbour object."
    }
}

Function Validate-EdgeOspfArea {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an OSPF Area element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name areaId -Membertype Properties)) { 
            throw "XML Element specified does not contain an areaId property."
        }
        if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
            throw "XML Element specified does not contain a type property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge OSPF Area object."
    }
}

Function Validate-EdgeOspfInterface {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an OSPF Area element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name areaId -Membertype Properties)) { 
            throw "XML Element specified does not contain an areaId property."
        }
        if ( -not ( $argument | get-member -name vnic -Membertype Properties)) { 
            throw "XML Element specified does not contain a vnic property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge OSPF Interface object."
    }
}

Function Validate-EdgeRedistributionRule {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an OSPF Area element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name learner -Membertype Properties)) { 
            throw "XML Element specified does not contain an areaId property."
        }
        if ( -not ( $argument | get-member -name id -Membertype Properties)) { 
            throw "XML Element specified does not contain an id property."
        }
        if ( -not ( $argument | get-member -name action -Membertype Properties)) { 
            throw "XML Element specified does not contain an action property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge Redistribution Rule object."
    }
}

Function Validate-LogicalRouterRouting {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an LogicalRouter routing element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name routingGlobalConfig -Membertype Properties)) { 
            throw "XML Element specified does not contain a routingGlobalConfig property."
        }
        if ( -not ( $argument | get-member -name enabled -Membertype Properties)) { 
            throw "XML Element specified does not contain an enabled property."
        }
        if ( -not ( $argument | get-member -name version -Membertype Properties)) { 
            throw "XML Element specified does not contain a version property."
        }
        if ( -not ( $argument | get-member -name logicalrouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalrouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter Routing object."
    }
}

Function Validate-LogicalRouterStaticRoute {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an LogicalRouter routing element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
            throw "XML Element specified does not contain a type property."
        }
        if ( -not ( $argument | get-member -name network -Membertype Properties)) { 
            throw "XML Element specified does not contain a network property."
        }
        if ( -not ( $argument | get-member -name nextHop -Membertype Properties)) { 
            throw "XML Element specified does not contain a nextHop property."
        }
        if ( -not ( $argument | get-member -name logicalrouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalrouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter Static Route object."
    }
}

Function Validate-LogicalRouterBgpNeighbour {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an LogicalRouter routing element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property."
        }
        if ( -not ( $argument | get-member -name remoteAS -Membertype Properties)) { 
            throw "XML Element specified does not contain a remoteAS property."
        }
        if ( -not ( $argument | get-member -name weight -Membertype Properties)) { 
            throw "XML Element specified does not contain a weight property."
        }
        if ( -not ( $argument | get-member -name holdDownTimer -Membertype Properties)) { 
            throw "XML Element specified does not contain a holdDownTimer property."
        }
        if ( -not ( $argument | get-member -name keepAliveTimer -Membertype Properties)) { 
            throw "XML Element specified does not contain a keepAliveTimer property."
        }
        if ( -not ( $argument | get-member -name logicalrouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalrouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter BGP Neighbour object."
    }
}

Function Validate-LogicalRouterOspfArea {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an OSPF Area element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name areaId -Membertype Properties)) { 
            throw "XML Element specified does not contain an areaId property."
        }
        if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
            throw "XML Element specified does not contain a type property."
        }
        if ( -not ( $argument | get-member -name logicalrouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalrouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter OSPF Area object."
    }
}

Function Validate-LogicalRouterOspfInterface {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an OSPF Area element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name areaId -Membertype Properties)) { 
            throw "XML Element specified does not contain an areaId property."
        }
        if ( -not ( $argument | get-member -name vnic -Membertype Properties)) { 
            throw "XML Element specified does not contain a vnic property."
        }
        if ( -not ( $argument | get-member -name logicalrouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalrouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter OSPF Interface object."
    }
}

Function Validate-LogicalRouterRedistributionRule {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an OSPF Area element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name learner -Membertype Properties)) { 
            throw "XML Element specified does not contain an areaId property."
        }
        if ( -not ( $argument | get-member -name id -Membertype Properties)) { 
            throw "XML Element specified does not contain an id property."
        }
        if ( -not ( $argument | get-member -name action -Membertype Properties)) { 
            throw "XML Element specified does not contain an action property."
        }
        if ( -not ( $argument | get-member -name logicalrouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalrouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter Redistribution Rule object."
    }
}

Function Validate-EdgePrefix {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an Edge prefix element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid Edge Prefix object."
    }
}

Function Validate-LogicalRouterPrefix {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )     

    #Check if it looks like an Edge prefix element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property."
        }
        if ( -not ( $argument | get-member -name logicalRouterId -Membertype Properties)) { 
            throw "XML Element specified does not contain an logicalRouterId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LogicalRouter Prefix object."
    }
}

Function Validate-EdgeInterface {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )    

    #Accepts an interface Object.
    if ($argument -is [System.Xml.XmlElement] ) {
        If ( $argument | get-member -name index -memberType Properties ) {

            #Looks like an interface object
            if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
                throw "XML Element specified does not contain a name property.  Specify a valid Edge Services Gateway Interface object."
            }
            if ( -not ( $argument | get-member -name label -Membertype Properties)) {
                throw "XML Element specified does not contain a label property.  Specify a valid Edge Services Gateway Interface object."
            }
            if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) {
                throw "XML Element specified does not contain an edgeId property.  Specify a valid Edge Services Gateway Interface object."
            }
        }
        else { 
            throw "Specify a valid Edge Services Gateway Interface object."
        }
    }
    else { 
        throw "Specify a valid Edge Services Gateway Interface object." 
    }
    $true
}

Function Validate-LogicalRouterInterface {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )    

    #Accepts an interface Object.
    if ($argument -is [System.Xml.XmlElement] ) {
        If ( $argument | get-member -name index -memberType Properties ) {

            #Looks like an interface object
            if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
                throw "XML Element specified does not contain a name property.  Specify a valid Logical Router Interface object"
            }
            if ( -not ( $argument | get-member -name label -Membertype Properties)) { 
                throw "XML Element specified does not contain a label property.  Specify a valid Logical Router Interface object"
            }
            if ( -not ( $argument | get-member -name logicalRouterId -Membertype Properties)) { 
                throw "XML Element specified does not contain an logicalRouterId property.  Specify a valid Logical Router Interface object"
            }
        }
        else { 
            throw "Specify a valid Logical Router Interface object."
        }
    }
    else { 
        throw "Specify a valid Logical Router Interface object." 
    }
    $true
}

Function Validate-EdgeSubInterface {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )  

    #Accepts a Subinterface Object.
    if ($argument -is [System.Xml.XmlElement] ) {
        If ( $argument | get-member -name vnicId -memberType Properties ) {

            #Looks like a Subinterface object
            if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
                throw "XML Element specified does not contain a edgeId property."
            }
            if ( -not ( $argument | get-member -name vnicId -Membertype Properties)) { 
                throw "XML Element specified does not contain a vnicId property."
            }
            if ( -not ( $argument | get-member -name index -Membertype Properties)) { 
                throw "XML Element specified does not contain an index property."
            }
            if ( -not ( $argument | get-member -name label -Membertype Properties)) { 
                throw "XML Element specified does not contain a label property."
            }
        }
        else { 
            throw "Object on pipeline is not a SubInterface object."
        }
    }
    else { 
        throw "Pipeline object was not a SubInterface object." 
    }
    $true
}

Function Validate-SecurityGroupMember { 
    
    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )  

    #Check types first - This is not 100% complete at this point!
    if (-not (
         ($argument -is [System.Xml.XmlElement]) -or 
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.DatacenterImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.VirtualPortGroupImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ResourcePoolImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Types.V1.VirtualDevice.NetworkAdapter] ))) {

            throw "Member is not a supported type.  Specify a Datacenter, Cluster, `
            DistributedPortGroup, PortGroup, ResourcePool, VirtualMachine, NetworkAdapter, `
            IPSet, SecurityGroup or Logical Switch object."      
    } 
    else {

        #Check if we have an ID property
        if ($argument -is [System.Xml.XmlElement] ) {
            if ( -not ( $argument | get-member -name objectId -Membertype Properties)) { 
                throw "XML Element specified does not contain an objectId property."
            }
            if ( -not ( $argument | get-member -name objectTypeName -Membertype Properties)) { 
                throw "XML Element specified does not contain a type property."
            }
            if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
                throw "XML Element specified does not contain a name property."
            }
            
            switch ($argument.objectTypeName) {

                "IPSet"{}
                "MacSet"{}
                "SecurityGroup" {}
                "VirtualWire" {}
                default { 
                    throw "Member is not a supported type.  Specify a Datacenter, Cluster, `
                         DistributedPortGroup, PortGroup, ResourcePool, VirtualMachine, NetworkAdapter, `
                         IPSet, MacSet, SecurityGroup or Logical Switch object." 
                }
            }
        }   
    }
    $true
}

Function Validate-FirewallRuleSourceDest {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )
    
    #Same requirements for SG membership.
    Validate-SecurityGroupMember $argument    
}

Function Validate-Service {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )
    if ( -not ($argument | get-member -MemberType Property -Name objectId )) { 
        throw "Invalid service object specified" 
    } 
    else { 
        $true
    }
}

Function Validate-FirewallAppliedTo {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check types first - currently missing edge handling!!!
    if (-not (
         ($argument -is [System.Xml.XmlElement]) -or 
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.DatacenterImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VMHostImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.VirtualPortGroupImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ResourcePoolImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl] ) -or
         ($argument -is [VMware.VimAutomation.ViCore.Types.V1.VirtualDevice.NetworkAdapter] ))) {

            throw "$($_.gettype()) is not a supported type.  Specify a Datacenter, Cluster, Host `
            DistributedPortGroup, PortGroup, ResourcePool, VirtualMachine, NetworkAdapter, `
            IPSet, SecurityGroup or Logical Switch object."
             
    } else {

        #Check if we have an ID property
        if ($argument -is [System.Xml.XmlElement] ) {
            if ( -not ( $argument | get-member -name objectId -Membertype Properties)) { 
                throw "XML Element specified does not contain an objectId property."
            }
            if ( -not ( $argument | get-member -name objectTypeName -Membertype Properties)) { 
                throw "XML Element specified does not contain a type property."
            }
            if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
                throw "XML Element specified does not contain a name property."
            }
            
            switch ($argument.objectTypeName) {

                "IPSet"{}
                "SecurityGroup" {}
                "VirtualWire" {}
                default { 
                    throw "AppliedTo is not a supported type.  Specify a Datacenter, Cluster, Host, `
                        DistributedPortGroup, PortGroup, ResourcePool, VirtualMachine, NetworkAdapter, `
                        IPSet, SecurityGroup or Logical Switch object." 
                }
            }
        }   
    }
    $true
}

Function Validate-LoadBalancer {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check if it looks like an LB element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name version -Membertype Properties)) { 
            throw "XML Element specified does not contain an version property."
        }
        if ( -not ( $argument | get-member -name enabled -Membertype Properties)) { 
            throw "XML Element specified does not contain an enabled property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LoadBalancer object."
    }
}

Function Validate-LoadBalancerMonitor {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check if it looks like an LB monitor element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name monitorId -Membertype Properties)) { 
            throw "XML Element specified does not contain a version property."
        }
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        if ( -not ( $argument | get-member -name type -Membertype Properties)) { 
            throw "XML Element specified does not contain a type property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LoadBalancer Monitor object."
    }
}

Function Validate-LoadBalancerVip {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check if it looks like an LB monitor element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name virtualServerId -Membertype Properties)) { 
            throw "XML Element specified does not contain a virtualServerId property."
        }
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        $true
    }
    else { 
        throw "Specify a valid LoadBalancer VIP object."
    }
}

Function Validate-LoadBalancerMemberSpec {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    if ($argument -is [System.Xml.XmlElement] ) {
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property.  Create with New-NsxLoadbalancerMemberSpec"
        }
        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property.  Create with New-NsxLoadbalancerMemberSpec"
        }
        if ( -not ( $argument | get-member -name weight -Membertype Properties)) { 
            throw "XML Element specified does not contain a weight property.  Create with New-NsxLoadbalancerMemberSpec"
        }
        if ( -not ( $argument | get-member -name port -Membertype Properties)) { 
            throw "XML Element specified does not contain a port property.  Create with New-NsxLoadbalancerMemberSpec"
        }
        if ( -not ( $argument | get-member -name minConn -Membertype Properties)) { 
            throw "XML Element specified does not contain a minConn property.  Create with New-NsxLoadbalancerMemberSpec"
        }
        if ( -not ( $argument | get-member -name maxConn -Membertype Properties)) { 
            throw "XML Element specified does not contain a maxConn property.  Create with New-NsxLoadbalancerMemberSpec"
        }            
        $true           
    }
    else { 
        throw "Specify a valid Member Spec object as created by New-NsxLoadBalancerMemberSpec."
    }
}

Function Validate-LoadBalancerApplicationProfile {

    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check if it looks like an LB applicationProfile element
    if ($argument -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name applicationProfileId -Membertype Properties)) { 
            throw "XML Element specified does not contain an applicationProfileId property."
        }
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        if ( -not ( $argument | get-member -name template -Membertype Properties)) { 
            throw "XML Element specified does not contain a template property."
        }
        $True
    }
    else { 
        throw "Specify a valid LoadBalancer Application Profile object."
    }
}

Function Validate-LoadBalancerPool {
 
    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check if it looks like an LB pool element
    if ($_ -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name poolId -Membertype Properties)) { 
            throw "XML Element specified does not contain an poolId property."
        }
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        $True
    }
    else { 
        throw "Specify a valid LoadBalancer Pool object."
    }
}

Function Validate-LoadBalancerPoolMember {
 
    Param (
        [Parameter (Mandatory=$true)]
        [object]$argument
    )

    #Check if it looks like an LB pool element
    if ($_ -is [System.Xml.XmlElement] ) {

        if ( -not ( $argument | get-member -name poolId -Membertype Properties)) { 
            throw "XML Element specified does not contain an poolId property."
        }
        if ( -not ( $argument | get-member -name edgeId -Membertype Properties)) { 
            throw "XML Element specified does not contain an edgeId property."
        }
        if ( -not ( $argument | get-member -name ipAddress -Membertype Properties)) { 
            throw "XML Element specified does not contain an ipAddress property."
        }
        if ( -not ( $argument | get-member -name port -Membertype Properties)) { 
            throw "XML Element specified does not contain a port property."
        }
        if ( -not ( $argument | get-member -name name -Membertype Properties)) { 
            throw "XML Element specified does not contain a name property."
        }
        $True
    }
    else { 
        throw "Specify a valid LoadBalancer Pool Member object."
    }
}

##########
##########
# Helper functions

function Format-XML () {

    #Shamelessly ripped from the web with some modification, useful for formatting XML output into a form that 
    #is easily read by humans.  Seriously - how is this not part of the dotnet system.xml classes?

    param ( 
        [Parameter (Mandatory=$false,ValueFromPipeline=$true,Position=1) ]
            $xml="", 
        [Parameter (Mandatory=$False)]
            [ValidateNotNullOrEmpty()]
            [int]$indent=2
    ) 

    if ( ($xml -is [System.Xml.XmlElement]) -or ( $xml -is [System.Xml.XmlDocument] ) ) { 
        try {
            [xml]$_xml = $xml.OuterXml 
        }
        catch {
            throw "Specified XML element cannot be cast to an XML document."
        }
    }
    elseif ( $xml -is [string] ) {
        try { 
            [xml]$_xml = $xml
        }
        catch {
            throw "Specified string cannot be cast to an XML document."
        } 
    }
    else{

        throw "Unknown data type specified as xml."
    }


    $StringWriter = New-Object System.IO.StringWriter 
    $XmlWriter = New-Object System.XMl.XmlTextWriter $StringWriter 
    $xmlWriter.Formatting = "indented" 
    $xmlWriter.Indentation = $Indent 
    $_xml.WriteContentTo($XmlWriter) 
    $XmlWriter.Flush() 
    $StringWriter.Flush() 
    Write-Output $StringWriter.ToString() 
}
Export-ModuleMember -function Format-Xml


##########
##########
# Core functions

function Connect-NsxServer {

    <#
    .SYNOPSIS
    Connects to the specified NSX server and constructs a connection object.

    .DESCRIPTION
    The Connect-NsxServer cmdlet connects to the specified NSX server and 
    retrieves version details.  Because the underlying REST protocol is not 
    connection oriented, the 'Connection' concept relates to just validating 
    endpoint details and credentials and storing some basic information used to 
    reproduce the same outcome during subsequent NSX operations.

    .EXAMPLE
    This example shows how to start an instance 

    PS C:\> Connect-NsxServer -Server nsxserver -username admin -Password 
        VMware1!


    #>

    [CmdletBinding(DefaultParameterSetName="cred")]
 
    param (
        [Parameter (Mandatory=$true,ParameterSetName="cred",Position=1)]
        [Parameter (ParameterSetName="userpass")]
            [ValidateNotNullOrEmpty()]
            [string]$Server,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]
            [ValidateRange(1,65535)]
            [int]$Port=443,
        [Parameter (Mandatory=$true,ParameterSetName="cred")]
            [PSCredential]$Credential,
        [Parameter (Mandatory=$true,ParameterSetName="userpass")]
            [ValidateNotNullOrEmpty()]
            [string]$Username,
        [Parameter (Mandatory=$true,ParameterSetName="userpass")]
            [ValidateNotNullOrEmpty()]
            [string]$Password,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]
            [ValidateNotNullOrEmpty()]
            [bool]$ValidateCertificate=$false,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]
            [ValidateNotNullOrEmpty()]
            [string]$Protocol="https",
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]
            [ValidateNotNullorEmpty()]
            [bool]$DefaultConnection=$true,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]   
            [bool]$DisableVIAutoConnect=$false,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]    
            [string]$VIUserName,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]    
            [string]$VIPassword,
        [Parameter (Mandatory=$false,ParameterSetName="cred")]
        [Parameter (ParameterSetName="userpass")]    
            [PSCredential]$VICred
    )

    if ($PSCmdlet.ParameterSetName -eq "userpass") {      
        $Credential = new-object System.Management.Automation.PSCredential($Username, $(ConvertTo-SecureString $Password -AsPlainText -Force))
    }

    $URI = "/api/1.0/appliance-management/global/info"
    
    #Test NSX connection
    try {
        $response = invoke-nsxrestmethod -cred $Credential -server $Server -port $port -protocol $Protocol -method "get" -uri $URI -ValidateCertificate $ValidateCertificate
    } 
    catch {

        Throw "Unable to connect to NSX Manager at $Server.  $_"
    }
    $connection = new-object PSCustomObject
    $Connection | add-member -memberType NoteProperty -name "Version" -value "$($response.VersionInfo.majorVersion).$($response.VersionInfo.minorVersion).$($response.VersionInfo.patchVersion)" -force
    $Connection | add-member -memberType NoteProperty -name "BuildNumber" -value "$($response.VersionInfo.BuildNumber)"
    $Connection | add-member -memberType NoteProperty -name "Credential" -value $Credential -force
    $connection | add-member -memberType NoteProperty -name "Server" -value $Server -force
    $connection | add-member -memberType NoteProperty -name "Port" -value $port -force
    $connection | add-member -memberType NoteProperty -name "Protocol" -value $Protocol -force
    $connection | add-member -memberType NoteProperty -name "ValidateCertificate" -value $ValidateCertificate -force
    $connection | add-member -memberType NoteProperty -name "VIConnection" -force -Value ""

    if ( $defaultConnection) { set-variable -name DefaultNSXConnection -value $connection -scope Global }
    
    #More and more functionality requires PowerCLI connection as well, so now pushing the user in that direction.  Will establish connection to vc the NSX manager 
    #is registered against.

    $vcInfo = Invoke-NsxRestMethod -method get -URI "/api/2.0/services/vcconfig"
    $RegisteredvCenterIP = $vcInfo.vcInfo.ipAddress
    $ConnectedToRegisteredVC=$false

    if ((test-path variable:global:DefaultVIServer )) {

        #Already have a PowerCLI connection - is it to the right place?

        #the 'ipaddress' in vcinfo from NSX api can be fqdn, 
        #Resolve to ip so we can compare to any existing connection.  
        #Resolution can result in more than one ip so we have to iterate over it.
        
        $RegisteredvCenterIPs = ([System.Net.Dns]::GetHostAddresses($RegisteredvCenterIP))

        #Remembering we can have multiple vCenter connections too :|
        :outer foreach ( $VIServerConnection in $global:DefaultVIServer ) {
            $ExistingVIConnectionIPs =  [System.Net.Dns]::GetHostAddresses($VIServerConnection.Name)
            foreach ( $ExistingVIConnectionIP in [IpAddress[]]$ExistingVIConnectionIPs ) {
                foreach ( $RegisteredvCenterIP in [IpAddress[]]$RegisteredvCenterIPs ) {
                    if ( $ExistingVIConnectionIP -eq $RegisteredvCenterIP ) {
                        if ( $VIServerConnection.IsConnected ) { 
                            $ConnectedToRegisteredVC = $true
                            write-host -foregroundcolor Green "Using existing PowerCLI connection to $($ExistingVIConnectionIP.IPAddresstoString)"
                            $connection.VIConnection = $VIServerConnection
                            break outer
                        }
                        else {
                            write-host -foregroundcolor Yellow "Existing PowerCLI connection to $($ExistingVIConnectionIP.IPAddresstoString) is not connected."
                        }
                    }
                }
            }
        }
    } 

    if ( -not $ConnectedToRegisteredVC ) {
        if ( -not (($VIUserName -and $VIPassword) -or ( $VICred ) )) {
            #We assume that if the user did not specify VI creds, then they may want a connection to VC, but we will ask.
            $decision = 1
            if ( -not $DisableVIAutoConnect) {
              
                #Ask the question and get creds.

                $message  = "PowerNSX requires a PowerCLI connection to the vCenter server NSX is registered against for proper operation."
                $question = "Automatically create PowerCLI connection to $($RegisteredvCenterIP)?"

                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)

            }

            if ( $decision -eq 0 ) { 
                write-host 
                write-host -foregroundcolor Yellow "Enter credentials for vCenter $RegisteredvCenterIP"
                $VICred = get-credential
                $connection.VIConnection = Connect-VIServer -Credential $VICred $RegisteredvCenterIP

            }
            else {
                write-host
                write-host -foregroundcolor Yellow "Some PowerNSX cmdlets will not be fully functional without a valid PowerCLI connection to vCenter server $RegisteredvCenterIP"
            }
        }
        else { 
            #User specified VI username/pwd or VI cred.  Connect automatically to the registered vCenter
            write-host "Creating PowerCLI connection to vCenter server $RegisteredvCenterIP"

            if ( $VICred ) { 
                $connection.VIConnection = Connect-VIServer -Credential $VICred $RegisteredvCenterIP
            }
            else {
                $connection.VIConnection = Connect-VIServer -User $VIUserName -Password $VIPassword $RegisteredvCenterIP
            }
        }
    }

    $connection
}
Export-ModuleMember -Function Connect-NsxServer

function Get-PowerNsxVersion {

    <#
    .SYNOPSIS
    Retrieves the version of PowerNSX.
    
    .EXAMPLE
    Get-PowerNsxVersion

    Get the instaled version of PowerNSX

    #>

    [PSCustomobject]@{
        "Version" = "1.0 RC1";
        "Major" = 1 ;
        "Minor" = 0;

    }
}
Export-ModuleMember -function Get-PowerNsxVersion {
    
}

#########
#########
# Infra functions

function Get-NsxClusterStatus {

    <#
    .SYNOPSIS
    Retrieves the resource status from NSX for the given cluster.

    .DESCRIPTION
    All clusters visible to NSX manager (managed by the vCenter that NSX Manager
    is synced with) can have the status of NSX related resources queried.

    This cmdlet returns the resource status of all registered NSX resources for 
    the given cluster.

    .EXAMPLE
    This example shows how to query the status for the cluster MyCluster 

    PS C:\> get-cluster MyCluster | Get-NsxClusterStatus

    .EXAMPLE
    This example shows how to query the status for all clusters

    PS C:\> get-cluster MyCluster | Get-NsxClusterStatus

    #>

    param (

        [Parameter ( Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl]$Cluster

    )

    begin {}

    process{
        #Get resource status for given cluster
        write-debug "$($MyInvocation.MyCommand.Name) : Query status for cluster $($cluster.name) ($($cluster.ExtensionData.Moref.Value))"
        $uri = "/api/2.0/nwfabric/status-without-alarms?resource=$($cluster.ExtensionData.Moref.Value)"
        try {
            $response = invoke-nsxrestmethod -connection $defaultNSXConnection -method get -uri $uri
            $response.resourceStatuses.resourceStatus.nwFabricFeatureStatus

        }
        catch {
            throw "Unable to query resource status for cluster $($cluster.Name) ($($cluster.ExtensionData.Moref.Value)).  $_"
        }
    }
    end{}
}
Export-ModuleMember -Function Get-NsxClusterStatus

function Parse-CentralCliResponse {

    param (
        [Parameter ( Mandatory=$True, Position=1)]
            [String]$response
    )


    #Response is straight text unfortunately, so there is no structure.  Having a crack at writing a very simple parser though the formatting looks.... challenging...
    
    #Control flags for handling list and table processing.
    $TableHeaderFound = $false
    $MatchedVnicsList = $false
    $MatchedRuleset = $false
    $MatchedAddrSet = $false

    $RuleSetName = ""
    $AddrSetName = ""

    $KeyValHash = @{}
    $KeyValHashUsed = $false

    #Defined this as variable as the swtich statement does not let me concat strings, which makes for a verrrrry long line...
    $RegexDFWRule = "^(?<Internal>#\sinternal\s#\s)?(?<RuleSetMember>rule\s)?(?<RuleId>\d+)\sat\s(?<Position>\d+)\s(?<Direction>in|out|inout)\s" + 
            "(?<Type>protocol|ethertype)\s(?<Service>.*?)\sfrom\s(?<Source>.*?)\sto\s(?<Destination>.*?)(?:\sport\s(?<Port>.*))?\s" + 
            "(?<Action>accept|reject|drop)(?:\swith\s(?<Log>log))?(?:\stag\s(?<Tag>'.*'))?;"



    foreach ( $line in ($response -split '[\r\n]')) { 

        #Init EntryHash hashtable
        $EntryHash= @{}

        switch -regex ($line.trim()) {

            #C CLI appears to emit some error conditions as ^ Error:<digits> 
            "^Error \d+:.*$" {

                write-debug "$($MyInvocation.MyCommand.Name) : Matched Error line. $_ "
                
                Throw "CLI command returned an error: ( $_ )"

            }

            "^\s*$" { 
                #Blank line, ignore...
                write-debug "$($MyInvocation.MyCommand.Name) : Ignoring blank line: $_"
                break

            }

            "^# Filter rules$" { 
                #Filter line encountered in a ruleset list, ignore...
                if ( $MatchedRuleSet ) { 
                    write-debug "$($MyInvocation.MyCommand.Name) : Ignoring meaningless #Filter rules line in ruleset: $_"
                    break
                }
                else {
                    throw "Error parsing Centralised CLI command output response.  Encountered #Filter rules line when not processing a ruleset: $_"
                }

            }
            #Matches a single integer of 1 or more digits at the start of the line followed only by a fullstop.
            #Example is the Index in a VNIC list.  AFAIK, the index should only be 1-9. but just in case we are matching 1 or more digit...
            "^(\d+)\.$" { 

                write-debug "$($MyInvocation.MyCommand.Name) : Matched Index line.  Discarding value: $_ "
                If ( $MatchedVnicsList ) { 
                    #We are building a VNIC list output and this is the first line.
                    #Init the output object to static kv props, but discard the value (we arent outputing as it appears superfluous.)
                    write-debug "$($MyInvocation.MyCommand.Name) : Processing Vnic List, initialising new Vnic list object"

                    $VnicListHash = @{}
                    $VnicListHash += $KeyValHash
                    $KeyValHashUsed = $true

                }
                break
            } 

            #Matches the start of a ruleset list.  show dfw host host-xxx filter xxx rules will output in rulesets like this
            "ruleset\s(\S+) {" {

                #Set a flag to say we matched a ruleset List, and create the output object.
                write-debug "$($MyInvocation.MyCommand.Name) : Matched start of DFW Ruleset output.  Processing following lines as DFW Ruleset: $_"
                $MatchedRuleset = $true 
                $RuleSetName = $matches[1].trim()
                break        
            }

            #Matches the start of a addrset list.  show dfw host host-xxx filter xxx addrset will output in addrsets like this
            "addrset\s(\S+) {" {

                #Set a flag to say we matched a addrset List, and create the output object.
                write-debug "$($MyInvocation.MyCommand.Name) : Matched start of DFW Addrset output.  Processing following lines as DFW Addrset: $_"
                $MatchedAddrSet = $true 
                $AddrSetName = $matches[1].trim()
                break        
            }

            #Matches a addrset entry.  show dfw host host-xxx filter xxx addrset will output in addrsets.
            "^(?<Type>ip|mac)\s(?<Address>.*),$" {

                #Make sure we were expecting it...
                if ( -not $MatchedAddrSet ) {
                    Throw "Error parsing Centralised CLI command output response.  Unexpected dfw addrset entry : $_" 
                }

                #We are processing a RuleSet, so we need to emit an output object that contains the ruleset name.
                [PSCustomobject]@{
                    "AddrSet" = $AddrSetName;
                    "Type" = $matches.Type;
                    "Address" = $matches.Address
                }

                break
            }

            #Matches a rule, either within a ruleset, or individually listed.  show dfw host host-xxx filter xxx rules will output in rulesets, 
            #or show dfw host-xxx filter xxx rule 1234 will output individual rule that should match.
            $RegexDFWRule {

                #Check if the rule is individual or part of ruleset...
                if ( $Matches.ContainsKey("RuleSetMember") -and (-not $MatchedRuleset )) {
                    Throw "Error parsing Centralised CLI command output response.  Unexpected dfw ruleset entry : $_" 
                }

                $Type = switch ( $matches.Type ) { "protocol" { "Layer3" } "ethertype" { "Layer2" }}
                $Internal = if ( $matches.ContainsKey("Internal")) { $true } else { $false }
                $Port = if ( $matches.ContainsKey("Port") ) { $matches.port } else { "Any" } 
                $Log = if ( $matches.ContainsKey("Log") ) { $true } else { $false } 
                $Tag = if ( $matches.ContainsKey("Tag") ) { $matches.Tag } else { "" } 

                If ( $MatchedRuleset ) {

                    #We are processing a RuleSet, so we need to emit an output object that contains the ruleset name.
                    [PSCustomobject]@{
                        "RuleSet" = $RuleSetName;
                        "InternalRule" = $Internal;
                        "RuleID" = $matches.RuleId;
                        "Position" = $matches.Position;
                        "Direction" = $matches.Direction;
                        "Type" = $Type;
                        "Service" = $matches.Service;
                        "Source" = $matches.Source;
                        "Destination" = $matches.Destination;
                        "Port" = $Port;
                        "Action" = $matches.Action;
                        "Log" = $Log;
                        "Tag" = $Tag

                    }
                }

                else {
                    #We are not processing a RuleSet; so we need to emit an output object without a ruleset name.
                    [PSCustomobject]@{
                        "InternalRule" = $Internal;
                        "RuleID" = $matches.RuleId;
                        "Position" = $matches.Position;
                        "Direction" = $matches.Direction;
                        "Type" = $Type;
                        "Service" = $matches.Service;
                        "Source" = $matches.Source;
                        "Destination" = $matches.Destination;
                        "Port" = $Port;
                        "Action" = $matches.Action;
                        "Log" = $Log;
                        "Tag" = $Tag
                    }
                }

                break
            }

            #Matches the end of a ruleset and addr lists.  show dfw host host-xxx filter xxx rules will output in lists like this
            "^}$" {

                if ( $MatchedRuleset ) { 

                    #Clear the flag to say we matched a ruleset List
                    write-debug "$($MyInvocation.MyCommand.Name) : Matched end of DFW ruleset."
                    $MatchedRuleset = $false
                    $RuleSetName = ""
                    break     
                }

                if ( $MatchedAddrSet ) { 
                   
                    #Clear the flag to say we matched an addrset List
                    write-debug "$($MyInvocation.MyCommand.Name) : Matched end of DFW addrset."
                    $MatchedAddrSet = $false
                    $AddrSetName = ""
                    break     
                }

                throw "Error parsing Centralised CLI command output response.  Encountered unexpected list completion character in line: $_"
            }

            #More Generic matches

            #Matches the generic KV case where we have _only_ two strings separated by more than one space.
            #This will do my head in later when I look at it, so the regex explanation is:
            #    - (?: gives non capturing group, we want to leverage $matches later, so dont want polluting groups.
            #    - (\S|\s(?!\s)) uses negative lookahead assertion to 'Match a non whitespace, or a single whitespace, as long as its not followed by another whitespace.
            #    - The rest should be self explanatory.
            "^((?:\S|\s(?!\s))+\s{2,}){1}((?:\S|\s(?!\s))+)$" { 

                write-debug "$($MyInvocation.MyCommand.Name) : Matched Key Value line (multispace separated): $_ )"
                
                $key = $matches[1].trim()
                $value = $matches[2].trim()
                If ( $MatchedVnicsList ) { 
                    #We are building a VNIC list output and this is one of the lines.
                    write-debug "$($MyInvocation.MyCommand.Name) : Processing Vnic List, Adding $key = $value to current VnicListHash"

                    $VnicListHash.Add($key,$value)

                    if ( $key -eq "Filters" ) {

                        #Last line in a VNIC List...
                        write-debug "$($MyInvocation.MyCommand.Name) : VNIC List :  Outputing VNIC List Hash."
                        [PSCustomobject]$VnicListHash
                    }
                }
                else {
                    #Add KV to hash table that we will append to output object
                    $KeyValHash.Add($key,$value)
                }     
                break
            }

            #Matches a general case output line containing Key: Value for properties that are consistent accross all entries in a table. 
            #This will match a line with multiple colons in it, not sure if thats an issue yet...
            "^((?:\S|\s(?!\s))+):((?:\S|\s(?!\s))+)$" {
                if ( $TableHeaderFound ) { Throw "Error parsing Centralised CLI command output response.  Key Value line found after header: ( $_ )" }
                write-debug "$($MyInvocation.MyCommand.Name) : Matched Key Value line (Colon Separated) : $_"
                
                #Add KV to hash table that we will append to output object
                $KeyValHash.Add($matches[1].trim(),$matches[2].trim())

                break
            }

            #Matches a Table header line.  This is a special case of the table entry line match, with the first element being ^No\.  Hoping that 'No.' start of the line is consistent :S
            "^No\.\s{2,}(.+\s{2,})+.+$" {
                if ( $TableHeaderFound ) { 
                    throw "Error parsing Centralised CLI command output response.  Matched header line more than once: ( $_ )"
                }
                write-debug "$($MyInvocation.MyCommand.Name) : Matched Table Header line: $_"
                $TableHeaderFound = $true
                $Props = $_.trim() -split "\s{2,}"
                break
            }

            #Matches the start of a Virtual Nics List output.  We process the output lines following this as a different output object
            "Virtual Nics List:" {
                #When central cli outputs a NIC 'list' it does so with a vertical list of Key Value rather than a table format, 
                #and with multi space as the KV separator, rather than a : like normal KV output.  WTF?
                #So Now I have to go forth and collate my nic object over the next few lines...
                #Example looks like this:

                #Virtual Nics List:
                #1.
                #Vnic Name      test-vm - Network adapter 1
                #Vnic Id        50012d15-198c-066c-af22-554aed610579.000
                #Filters        nic-4822904-eth0-vmware-sfw.2

                #Set a flag to say we matched a VNic List, and create the output object initially with just the KV's matched already.
                write-debug "$($MyInvocation.MyCommand.Name) : Matched VNIC List line.  Processing remaining lines as Vnic List: $_"
                $MatchedVnicsList = $true 
                break                       

            }

            #Matches a table entry line.  At least three properties (that may contain a single space) separated by more than one space.
            "^((?:\S|\s(?!\s))+\s{2,}){2,}((?:\S|\s(?!\s))+)$" {
                if ( -not $TableHeaderFound ) { 
                    throw "Error parsing Centralised CLI command output response.  Matched table entry line before header: ( $_ )"
                }
                write-debug "$($MyInvocation.MyCommand.Name) : Matched Table Entry line: $_"
                $Vals = $_.trim() -split "\s{2,}"
                if ($Vals.Count -ne $Props.Count ) { 
                    Throw "Error parsing Centralised CLI command output response.  Table entry line contains different value count compared to properties count: ( $_ )"
                }

                #Build the output hashtable with the props returned in the table entry line
                for ( $i= 0; $i -lt $props.count; $i++ ) {

                    #Ordering is hard, and No. entry is kinda superfluous, so removing it from output (for now)
                    if ( -not ( $props[$i] -eq "No." )) {
                        $EntryHash[$props[$i].trim()]=$vals[$i].trim()
                    }
                }

                #Add the KV pairs that were parsed before the table.
                try {

                    #This may fail if we have a key of the same name.  For the moment, Im going to assume that this wont happen...
                    $EntryHash += $KeyValHash
                    $KeyValHashUsed = $true
                }
                catch {
                    throw "Unable to append static Key Values to EntryHash output object.  Possibly due to a conflicting key"
                }

                #Emit the entry line as a PSCustomobject :)
                [PSCustomObject]$EntryHash
                break
            }
            default { throw "Unable to parse Centralised CLI output line : $($_ -replace '\s','_')" } 
        }
    }

    if ( (-not $KeyValHashUsed) -and $KeyValHash.count -gt 0 ) {

        #Some output is just key value, so, if it hasnt been appended to output object already, we will just emit it.
        #Not sure how this approach will work long term, but it works for show dfw vnic <>
        write-debug "$($MyInvocation.MyCommand.Name) : KeyValHash has not been used after all line processing, outputing as is: $_"
        [PSCustomObject]$KeyValHash
    }
}

function Invoke-NsxCli {

    <#
    .SYNOPSIS
    Provides access to the NSX Centralised CLI.

    .DESCRIPTION
    The NSX Centralised CLI is a feature first introduced in NSX 6.2.  It 
    provides centralised means of performing read only operations against 
    various aspects of the dataplane including Logical Switching, Logical 
    Routing, Distributed Firewall and Edge Services Gateways.

    The results returned by the Centralised CLI are actual (realised) state
    as opposed to configured state.  They should you how the dataplane actually
    is configured at the time the query is run.

    The Centralised CLI is primarily a trouble shooting tool.

    #>

    param (

        [Parameter ( Mandatory=$true, Position=1) ]
            [ValidateNotNullOrEmpty()]
            [String]$Query,
        [Parameter ( Mandatory=$false) ]
            [switch]$SupressWarning
               
    )

    begin{ 
        if ( -not $SupressWarning ) {
            write-warning "This cmdlet is experimental and has not been completely tested.  Use with caution and report any errors." 
        }
    }

    process{


        write-debug "$($MyInvocation.MyCommand.Name) : Executing Central CLI query $Query"
        
        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlCli = $XMLDoc.CreateElement("nsxcli")
        $xmlDoc.appendChild($xmlCli) | out-null

        Add-XmlElement -xmlRoot $xmlCli -xmlElementName "command" -xmlElementText $Query

        #<nsxcli><command>show cluster all</command></nsxcli>

        $Body = $xmlCli.OuterXml
        $uri = "/api/1.0/nsx/cli?action=execute"
        try {
            $response = invoke-nsxrestmethod -connection $defaultNSXConnection -method post -uri $uri -Body $Body
            Parse-CentralCliResponse $response
        }
        catch {

            throw "Unable to execute Centralised CLI query.  $_"
        }
    }
    end{}
}
Export-ModuleMember -Function Invoke-NsxCli

function Get-NsxCliDfwFilter {

    <#
    .SYNOPSIS
    Uses the NSX Centralised CLI to retreive the VMs VNIC filters.

    .DESCRIPTION
    The NSX Centralised CLI is a feature first introduced in NSX 6.2.  It 
    provides centralised means of performing read only operations against 
    various aspects of the dataplane including Logical Switching, Logical 
    Routing, Distributed Firewall and Edge Services Gateways.

    The results returned by the Centralised CLI are actual (realised) state
    as opposed to configured state.  They show you how the dataplane actually
    is configured at the time the query is run.

    This cmdlet accepts a VM object, and leverages the Invoke-NsxCli cmdlet by 
    constructing the appropriate Centralised CLI command without requiring the 
    user to do the show cluster all -> show cluster domain-xxx -> show host 
    host-xxx -> show vm vm-xxx dance -> show dfw host host-xxx filter xxx rules
    dance.  It returns objects representing the Filters defined on each vnic of 
    the VM

    #>

    Param ( 
        [Parameter (Mandatory=$True, ValueFromPipeline=$True)]
            [ValidateNotNullorEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VirtualMachine
    )

    begin{}

    process{

        $query = "show vm $($VirtualMachine.ExtensionData.Moref.Value)"
        $filters = Invoke-NsxCli $query -SupressWarning
        
        foreach ( $filter in $filters ) { 
            #Execute the appropriate CLI query against the VMs host for the current filter...
            $query = "show vnic $($Filter."Vnic Id")"
            Invoke-NsxCli $query -SupressWarning
        }
    }

    end{}
}
Export-ModuleMember -Function Get-NsxCliDfwFilter

function Get-NsxCliDfwRule {

    <#
    .SYNOPSIS
    Uses the NSX Centralised CLI to retreive the rules configured for the 
    specified VMs vnics.

    .DESCRIPTION
    The NSX Centralised CLI is a feature first introduced in NSX 6.2.  It 
    provides centralised means of performing read only operations against 
    various aspects of the dataplane including Logical Switching, Logical 
    Routing, Distributed Firewall and Edge Services Gateways.

    The results returned by the Centralised CLI are actual (realised) state
    as opposed to configured state.  They show you how the dataplane actually
    is configured at the time the query is run.

    This cmdlet accepts a VM object, and leverages the Invoke-NsxCli cmdlet by 
    constructing the appropriate Centralised CLI command without requiring the 
    user to do the show cluster all -> show cluster domain-xxx -> show host 
    host-xxx -> show vm vm-xxx dance -> show dfw host host-xxx filter xxx
    dance.  It returns objects representing the DFW rules instantiated on 
    the VMs vnics dfw filters.

    #>

    Param ( 
        [Parameter (Mandatory=$True, ValueFromPipeline=$True)]
            [ValidateNotNullorEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VirtualMachine
    )

    begin{}

    process{

        if ( $VirtualMachine.PowerState -eq 'PoweredOn' ) { 
            #First we retrieve the filter names from the host that the VM is running on
            try { 
                $query = "show vm $($VirtualMachine.ExtensionData.Moref.Value)"
                $VMs = Invoke-NsxCli $query -SupressWarning
            }
            catch {
                #Invoke-nsxcli threw an exception.  There are a couple we want to handle here...
                switch -regex ($_.tostring()) {
                    "\( Error 100: \)" { 
                        write-warning "Virtual Machine $($VirtualMachine.Name) has no DFW Filter active."; 
                        return                    }
                    default {throw}
                } 
            }

            #Potentially there are multiple 'VMs' (VM with more than one NIC).
            foreach ( $VM in $VMs ) { 
                #Execute the appropriate CLI query against the VMs host for the current filter...
                $query = "show dfw host $($VirtualMachine.VMHost.ExtensionData.MoRef.Value) filter $($VM.Filters) rules"
                $rule = Invoke-NsxCli $query -SupressWarning
                $rule | add-member -memberType NoteProperty -Name "VirtualMachine" -Value $VirtualMachine
                $rule | add-member -memberType NoteProperty -Name "Filter" -Value $($VM.Filters)
                $rule
            }
        } else {
            write-warning "Virtual Machine $($VirtualMachine.Name) is not powered on."
        }
    }
    end{}
}
Export-ModuleMember -Function Get-NsxCliDfwRule

function Get-NsxCliDfwAddrSet {

    <#
    .SYNOPSIS
    Uses the NSX Centralised CLI to retreive the address sets configured
    for the specified VMs vnics.

    .DESCRIPTION
    The NSX Centralised CLI is a feature first introduced in NSX 6.2.  It 
    provides centralised means of performing read only operations against 
    various aspects of the dataplane including Logical Switching, Logical 
    Routing, Distributed Firewall and Edge Services Gateways.

    The results returned by the Centralised CLI are actual (realised) state
    as opposed to configured state.  They show you how the dataplane actually
    is configured at the time the query is run.

    This cmdlet accepts a VM object, and leverages the Invoke-NsxCli cmdlet by 
    constructing the appropriate Centralised CLI command without requiring the 
    user to do the show cluster all -> show cluster domain-xxx -> show host 
    host-xxx -> show vm vm-xxx dance -> show dfw host host-xxx filter xxx
    dance.  It returns object representing the Address Sets defined on the 
    VMs vnics DFW filters. 

    #>

    Param ( 
        [Parameter (Mandatory=$True, ValueFromPipeline=$True)]
            [ValidateNotNullorEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VirtualMachine
    )

    begin{}

    process{

        #First we retrieve the filter names from the host that the VM is running on
        $query = "show vm $($VirtualMachine.ExtensionData.Moref.Value)"
        $Filters = Invoke-NsxCli $query -SupressWarning

        #Potentially there are multiple filters (VM with more than one NIC).
        foreach ( $filter in $filters ) { 
            #Execute the appropriate CLI query against the VMs host for the current filter...
            $query = "show dfw host $($VirtualMachine.VMHost.ExtensionData.MoRef.Value) filter $($Filter.Filters) addrset"
            Invoke-NsxCli $query -SupressWarning
        }
    }
    end{}
}
Export-ModuleMember -Function Get-NsxCliDfwAddrSet




#########
#########
# L2 related functions

function Get-NsxTransportZone {

    <#
    .SYNOPSIS
    Retrieves a TransportZone object.

    .DESCRIPTION
    Transport Zones are used to control the scope of logical switches within 
    NSX.  A Logical Switch is 'bound' to a transport zone, and only hosts that 
    are members of the Transport Zone are able to host VMs connected to a 
    Logical Switch that is bound to it.  All Logical Switch operations require a
    Transport Zone.
    
    .EXAMPLE
    PS C:\> Get-NsxTransportZone -name TestTZ
    
    #>


    param (
        [Parameter (Mandatory=$false,Position=1)]
        [string]$name

    )

    $URI = "/api/2.0/vdn/scopes"
    $response = invoke-nsxrestmethod -method "get" -uri $URI
    
    if ( $name ) { 
        $response.vdnscopes.vdnscope | ? { $_.name -eq $name }
    } else {
        $response.vdnscopes.vdnscope
    }
}
Export-ModuleMember -Function Get-NsxTransportZone

function Get-NsxLogicalSwitch {


    <#
    .SYNOPSIS
    Retrieves a Logical Switch object

    .DESCRIPTION
    An NSX Logical Switch provides L2 connectivity to VMs attached to it.
    A Logical Switch is 'bound' to a Transport Zone, and only hosts that are 
    members of the Transport Zone are able to host VMs connected to a Logical 
    Switch that is bound to it.  All Logical Switch operations require a 
    Transport Zone.
    
    .EXAMPLE
    
    Example1: Get a named Logical Switch
    PS C:\> Get-NsxTransportZone | Get-NsxLogicalswitch -name LS1
    
    Example2: Get all logical switches in a given transport zone.
    PS C:\> Get-NsxTransportZone | Get-NsxLogicalswitch
    
    #>

    [CmdletBinding(DefaultParameterSetName="vdnscope")]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,ParameterSetName="vdnscope")]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$vdnScope,
        [Parameter (Mandatory=$false,Position=1)]
            [string]$name,
        [Parameter (Mandatory=$true,ParameterSetName="virtualWire")]
            [ValidateNotNullOrEmpty()]
            [string]$virtualWireId

    )
    
    begin {

    }

    process {
    
        if ( $psCmdlet.ParameterSetName -eq "virtualWire" ) {

            #Just getting a single named Logical Switch
            $URI = "/api/2.0/vdn/virtualwires/$virtualWireId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $response.virtualWire

        }
        else { 
            
            #Getting all LS in a given VDNScope
            $lspagesize = 10        
            $URI = "/api/2.0/vdn/scopes/$($vdnScope.objectId)/virtualwires?pagesize=$lspagesize&startindex=00"
            $response = invoke-nsxrestmethod -method "get" -uri $URI

            $logicalSwitches = @()

            #LS XML is returned as paged data, means we have to handle it.  
            #May refactor this later, depending on where else I find this in the NSX API (its not really documented in the API guide)
        
            $itemIndex =  0
            $startingIndex = 0 
            $pagingInfo = $response.virtualWires.dataPage.pagingInfo
        
            
            if ( [int]$paginginfo.totalCount -ne 0 ) {
                 write-debug "$($MyInvocation.MyCommand.Name) : Logical Switches count non zero"

                do {
                    write-debug "$($MyInvocation.MyCommand.Name) : In paging loop. PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"

                    while (($itemindex -lt ([int]$paginginfo.pagesize + $startingIndex)) -and ($itemIndex -lt [int]$paginginfo.totalCount )) {
            
                        write-debug "$($MyInvocation.MyCommand.Name) : In Item Processing Loop: ItemIndex: $itemIndex"
                        write-debug "$($MyInvocation.MyCommand.Name) : $(@($response.virtualwires.datapage.virtualwire)[($itemIndex - $startingIndex)].objectId)"
                    
                        #Need to wrap the virtualwire prop of the datapage in case we get exactly 1 item - 
                        #which powershell annoyingly unwraps to a single xml element rather than an array...
                        $logicalSwitches += @($response.virtualwires.datapage.virtualwire)[($itemIndex - $startingIndex)]
                        $itemIndex += 1 
                    }  
                    write-debug "$($MyInvocation.MyCommand.Name) : Out of item processing - PagingInfo: PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"
                    if ( [int]$paginginfo.totalcount -gt $itemIndex) {
                        write-debug "$($MyInvocation.MyCommand.Name) : PagingInfo: PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"
                        $startingIndex += $lspagesize
                        $URI = "/api/2.0/vdn/scopes/$($vdnScope.objectId)/virtualwires?pagesize=$lspagesize&startindex=$startingIndex"
                
                        $response = invoke-nsxrestmethod -method "get" -uri $URI
                        $pagingInfo = $response.virtualWires.dataPage.pagingInfo
                    
    
                    } 
                } until ( [int]$paginginfo.totalcount -le $itemIndex )    
                write-debug "$($MyInvocation.MyCommand.Name) : Completed page processing: ItemIndex: $itemIndex"

            }

            if ( $name ) { 
                $logicalSwitches | ? { $_.name -eq $name }
            } else {
                $logicalSwitches
            }
        }
    }
    end {

    }
}
Export-ModuleMember -Function Get-NsxLogicalSwitch

function New-NsxLogicalSwitch  {

    <#
    .SYNOPSIS
    Creates a new Logical Switch

    .DESCRIPTION
    An NSX Logical Switch provides L2 connectivity to VMs attached to it.
    A Logical Switch is 'bound' to a Transport Zone, and only hosts that are 
    members of the Transport Zone are able to host VMs connected to a Logical 
    Switch that is bound to it.  All Logical Switch operations require a 
    Transport Zone.  A new Logical Switch defaults to the control plane mode of 
    the Transport Zone it is created in, but CP mode can specified as required.

    .EXAMPLE

    Example1: Create a Logical Switch with default control plane mode.
    PS C:\> Get-NsxTransportZone | New-NsxLogicalSwitch -name LS6 

    Example2: Create a Logical Switch with a specific control plane mode.
    PS C:\> Get-NsxTransportZone | New-NsxLogicalSwitch -name LS6 
        -ControlPlaneMode MULTICAST_MODE
    
    #>


    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateNotNullOrEmpty()]
            [System.XML.XMLElement]$vdnScope,
        [Parameter (Mandatory=$true,Position=1)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$Description = "",
        [Parameter (Mandatory=$false)]
            [string]$TenantId = "",
        [Parameter (Mandatory=$false)]
            [ValidateSet("UNICAST_MODE","MULTICAST_MODE","HYBRID_MODE")]
            [string]$ControlPlaneMode
    )

    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("virtualWireCreateSpec")
        $xmlDoc.appendChild($xmlRoot) | out-null


        #Create an Element and append it to the root
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "description" -xmlElementText $Description
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "tenantId" -xmlElementText $TenantId
        if ( $ControlPlaneMode ) { Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "controlPlaneMode" -xmlElementText $ControlPlaneMode } 
           
        #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/2.0/vdn/scopes/$($vdnscope.objectId)/virtualwires"
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body

        #response only contains the vwire id, we have to query for it to get output consisten with get-nsxlogicalswitch
        Get-NsxLogicalSwitch -virtualWireId $response
    }
    end {}
}
Export-ModuleMember -Function New-NsxLogicalSwitch

function Remove-NsxLogicalSwitch {

    <#
    .SYNOPSIS
    Removes a Logical Switch

    .DESCRIPTION
    An NSX Logical Switch provides L2 connectivity to VMs attached to it.
    A Logical Switch is 'bound' to a Transport Zone, and only hosts that are 
    members of the Transport Zone are able to host VMs connected to a Logical 
    Switch that is bound to it.  All Logical Switch operations require a 
    Transport Zone.

    .EXAMPLE

    Example1: Remove a Logical Switch
    PS C:\> Get-NsxTransportZone | Get-NsxLogicalSwitch LS6 | 
        Remove-NsxLogicalSwitch 

    Example2: Remove a Logical Switch without confirmation. 
    PS C:\> Get-NsxTransportZone | Get-NsxLogicalSwitch LS6 | 
        Remove-NsxLogicalSwitch -confirm:$false
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$virtualWire,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true

    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Logical Switch removal is permanent."
            $question = "Proceed with removal of Logical Switch $($virtualWire.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            $URI = "/api/2.0/vdn/virtualwires/$($virtualWire.ObjectId)"
            Write-Progress -activity "Remove Logical Switch $($virtualWire.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove Logical Switch $($virtualWire.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalSwitch

#########
######### 
# Distributed Router functions


function New-NsxLogicalRouterInterfaceSpec {

    <#
    .SYNOPSIS
    Creates a new NSX Logical Router Interface Spec.

    .DESCRIPTION
    NSX Logical Routers can host up to 1000 interfaces, each of which can be 
    configured with multiple properties.  In order to allow creation of Logical 
    Routers with an arbitrary number of interfaces, a unique spec for each interface 
    required must first be created.

    Logical Routers do support interfaces on VLAN backed portgroups, and this 
    cmdlet will support a interface spec connected to a normal portgroup, however 
    this is not noramlly a recommended scenario.
    
    .EXAMPLE

    PS C:\> $Uplink = New-NsxLogicalRouterinterfaceSpec -Name Uplink_interface -Type 
        uplink -ConnectedTo (Get-NsxTransportZone | Get-NsxLogicalSwitch LS1) 
        -PrimaryAddress 192.168.0.1 -SubnetPrefixLength 24

    PS C:\> $Internal = New-NsxLogicalRouterinterfaceSpec -Name Internal-interface -Type 
        internal -ConnectedTo (Get-NsxTransportZone | Get-NsxLogicalSwitch LS2) 
        -PrimaryAddress 10.0.0.1 -SubnetPrefixLength 24
    
    #>


     param (
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateSet ("internal","uplink")]
            [string]$Type,
        [Parameter (Mandatory=$false)]
            [ValidateScript({Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$ConnectedTo,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU=1500,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Connected=$true,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,1000)]
            [int]$Index 
    )

    begin {

        if ( $Connected -and ( -not $connectedTo ) ) { 
            #Not allowed to be connected without a connected port group.
            throw "Interfaces that are connected must be connected to a distributed Portgroup or Logical Switch."
        }

        if (( $PsBoundParameters.ContainsKey("PrimaryAddress") -and ( -not $PsBoundParameters.ContainsKey("SubnetPrefixLength"))) -or 
            (( -not $PsBoundParameters.ContainsKey("PrimaryAddress")) -and  $PsBoundParameters.ContainsKey("SubnetPrefixLength"))) {

            #Not allowed to have subnet without primary or vice versa.
            throw "Interfaces with a Primary address must also specify a prefix length and vice versa."   
        }
    }

    process { 

        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlVnic = $XMLDoc.CreateElement("interface")
        $xmlDoc.appendChild($xmlVnic) | out-null

        if ( $PsBoundParameters.ContainsKey("Name")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "name" -xmlElementText $Name }
        if ( $PsBoundParameters.ContainsKey("Type")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "type" -xmlElementText $type }
        if ( $PsBoundParameters.ContainsKey("Index")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "index" -xmlElementText $Index }
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "mtu" -xmlElementText $MTU 
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "isConnected" -xmlElementText $Connected

        switch ($ConnectedTo){
            { ($_ -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl]) -or ( $_ -is [VMware.VimAutomation.Vds.Impl.VDObjectImpl] ) }  { $PortGroupID = $_.ExtensionData.MoRef.Value }
            { $_ -is [System.Xml.XmlElement]} { $PortGroupID = $_.objectId }
        }  

        if ( $PsBoundParameters.ContainsKey("ConnectedTo")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "connectedToId" -xmlElementText $PortGroupID }

        if ( $PsBoundParameters.ContainsKey("PrimaryAddress")) {

            #For now, only supporting one addressgroup - will refactor later
            [System.XML.XMLElement]$xmlAddressGroups = $XMLDoc.CreateElement("addressGroups")
            $xmlVnic.appendChild($xmlAddressGroups) | out-null
            $AddressGroupParameters = @{
                xmldoc = $xmlDoc 
                xmlAddressGroups = $xmlAddressGroups
            }

            if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $AddressGroupParameters.Add("PrimaryAddress",$PrimaryAddress) }
            if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $AddressGroupParameters.Add("SubnetPrefixLength",$SubnetPrefixLength) }
             
            New-NsxEdgeVnicAddressGroup @AddressGroupParameters
        
        }
        $xmlVnic
    }
    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterInterfaceSpec


function Get-NsxLogicalRouter {

    <#
    .SYNOPSIS
    Retrieves a Logical Router object.
    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    This cmdlet returns Logical Router objects.
    
    .EXAMPLE
    PS C:\> Get-NsxLogicalRouter LR1

    #>
    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ParameterSetName="objectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name

    )

    $pagesize = 10         
    switch ( $psCmdlet.ParameterSetName ) {

        "Name" { 
            $URI = "/api/4.0/edges?pageSize=$pagesize&startIndex=00" 
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            
            #Edge summary XML is returned as paged data, means we have to handle it.  
            #Then we have to query for full information on a per edge basis.
            $edgesummaries = @()
            $edges = @()
            $itemIndex =  0
            $startingIndex = 0 
            $pagingInfo = $response.pagedEdgeList.edgePage.pagingInfo
            
            if ( [int]$paginginfo.totalCount -ne 0 ) {
                 write-debug "$($MyInvocation.MyCommand.Name) : Logical Router count non zero"

                do {
                    write-debug "$($MyInvocation.MyCommand.Name) : In paging loop. PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"

                    while (($itemindex -lt ([int]$paginginfo.pagesize + $startingIndex)) -and ($itemIndex -lt [int]$paginginfo.totalCount )) {
            
                        write-debug "$($MyInvocation.MyCommand.Name) : In Item Processing Loop: ItemIndex: $itemIndex"
                        write-debug "$($MyInvocation.MyCommand.Name) : $(@($response.pagedEdgeList.edgePage.edgeSummary)[($itemIndex - $startingIndex)].objectId)"
                    
                        #Need to wrap the edgesummary prop of the datapage in case we get exactly 1 item - 
                        #which powershell annoyingly unwraps to a single xml element rather than an array...
                        $edgesummaries += @($response.pagedEdgeList.edgePage.edgeSummary)[($itemIndex - $startingIndex)]
                        $itemIndex += 1 
                    }  
                    write-debug "$($MyInvocation.MyCommand.Name) : Out of item processing - PagingInfo: PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"
                    if ( [int]$paginginfo.totalcount -gt $itemIndex) {
                        write-debug "$($MyInvocation.MyCommand.Name) : PagingInfo: PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"
                        $startingIndex += $pagesize
                        $URI = "/api/4.0/edges?pageSize=$pagesize&startIndex=$startingIndex"
                
                        $response = invoke-nsxrestmethod -method "get" -uri $URI
                        $pagingInfo = $response.pagedEdgeList.edgePage.pagingInfo
                    

                    } 
                } until ( [int]$paginginfo.totalcount -le $itemIndex )    
                write-debug "$($MyInvocation.MyCommand.Name) : Completed page processing: ItemIndex: $itemIndex"
            }

            #What we got here is...failure to communicate!  In order to get full detail, we have to requery for each edgeid.
            #But... there is information in the SUmmary that isnt in the full detail.  So Ive decided to add the summary as a node 
            #to the returned edge detail. 

            foreach ($edgesummary in $edgesummaries) {

                $URI = "/api/4.0/edges/$($edgesummary.objectID)" 
                $response = invoke-nsxrestmethod -method "get" -uri $URI
                $import = $response.edge.ownerDocument.ImportNode($edgesummary, $true)
                $response.edge.appendChild($import) | out-null                
                $edges += $response.edge

            }

            if ( $name ) { 
                $edges | ? { $_.Type -eq 'distributedRouter' } | ? { $_.name -eq $name }

            } else {
                $edges | ? { $_.Type -eq 'distributedRouter' }

            }

        }

        "objectId" { 

            $URI = "/api/4.0/edges/$objectId" 
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $edge = $response.edge
            $URI = "/api/4.0/edges/$objectId/summary" 
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $import = $edge.ownerDocument.ImportNode($($response.edgeSummary), $true)
            $edge.AppendChild($import) | out-null
            $edge

        }
    }
}
Export-ModuleMember -Function Get-NsxLogicalRouter

function New-NsxLogicalRouter {

    <#
    .SYNOPSIS
    Creates a new Logical Router object.
    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    This cmdlet creates a new Logical Router.  A Logical router has many 
    configuration options - not all are exposed with New-NsxLogicalRouter.  
    Use Set-NsxLogicalRouter for other configuration.

    Interface configuration is handled by passing interface spec objects created by 
    the New-NsxLogicalRouterInterfaceSpec cmdlet.

    A valid PowerCLI session is required to pass required objects as required by 
    cluster/resourcepool and datastore parameters.
    
    .EXAMPLE
    
    Create a new LR with interfaces on existsing Logical switches (LS1,2,3 and 
    Management interface on Mgmt)

    PS C:\> $ls1 = get-nsxtransportzone | get-nsxlogicalswitch LS1

    PS C:\> $ls2 = get-nsxtransportzone | get-nsxlogicalswitch LS2

    PS C:\> $ls3 = get-nsxtransportzone | get-nsxlogicalswitch LS3

    PS C:\> $mgt = get-nsxtransportzone | get-nsxlogicalswitch Mgmt

    PS C:\> $vnic0 = New-NsxLogicalRouterInterfaceSpec -Type uplink -Name vNic0 
        -ConnectedTo $ls1 -PrimaryAddress 1.1.1.1 -SubnetPrefixLength 24

    PS C:\> $vnic1 = New-NsxLogicalRouterInterfaceSpec -Type internal -Name vNic1 
        -ConnectedTo $ls2 -PrimaryAddress 2.2.2.1 -SubnetPrefixLength 24

    PS C:\> $vnic2 = New-NsxLogicalRouterInterfaceSpec -Type internal -Name vNic2 
        -ConnectedTo $ls3 -PrimaryAddress 3.3.3.1 -SubnetPrefixLength 24

    PS C:\> New-NsxLogicalRouter -Name testlr -ManagementPortGroup $mgt 
        -Interface $vnic0,$vnic1,$vnic2 -Cluster (Get-Cluster) 
        -Datastore (get-datastore)

    #>

    param (
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$ManagementPortGroup,
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LogicalRouterInterfaceSpec $_ })]
            [System.Xml.XmlElement[]]$Interface,       
        [Parameter (Mandatory=$true,ParameterSetName="ResourcePool")]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ResourcePoolImpl]$ResourcePool,
        [Parameter (Mandatory=$true,ParameterSetName="Cluster")]
            [ValidateScript({
                if ( $_ -eq $null ) { throw "Must specify Cluster."}
                if ( -not $_.DrsEnabled ) { throw "Cluster is not DRS enabled."}
                $true
            })]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl]$Cluster,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.DatastoreImpl]$Datastore,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$EnableHA=$false,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.DatastoreImpl]$HADatastore=$datastore

    )


    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("edge")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "type" -xmlElementText "distributedRouter"

        switch ($ManagementPortGroup){

            { $_ -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl] -or $_ -is [VMware.VimAutomation.Vds.Impl.VDObjectImpl] }  { $PortGroupID = $_.ExtensionData.MoRef.Value }
            { $_ -is [System.Xml.XmlElement]} { $PortGroupID = $_.objectId }

        }

        [System.XML.XMLElement]$xmlMgmtIf = $XMLDoc.CreateElement("mgmtInterface")
        $xmlRoot.appendChild($xmlMgmtIf) | out-null
        Add-XmlElement -xmlRoot $xmlMgmtIf -xmlElementName "connectedToId" -xmlElementText $PortGroupID

        [System.XML.XMLElement]$xmlAppliances = $XMLDoc.CreateElement("appliances")
        $xmlRoot.appendChild($xmlAppliances) | out-null
        
        switch ($psCmdlet.ParameterSetName){

            "Cluster"  { $ResPoolId = $($cluster | get-resourcepool | ? { $_.parent.id -eq $cluster.id }).extensiondata.moref.value }
            "ResourcePool"  { $ResPoolId = $ResourcePool.extensiondata.moref.value }

        }

        [System.XML.XMLElement]$xmlAppliance = $XMLDoc.CreateElement("appliance")
        $xmlAppliances.appendChild($xmlAppliance) | out-null
        Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "resourcePoolId" -xmlElementText $ResPoolId
        Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "datastoreId" -xmlElementText $datastore.extensiondata.moref.value

        if ( $EnableHA ) {
            [System.XML.XMLElement]$xmlAppliance = $XMLDoc.CreateElement("appliance")
            $xmlAppliances.appendChild($xmlAppliance) | out-null
            Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "resourcePoolId" -xmlElementText $ResPoolId
            Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "datastoreId" -xmlElementText $HAdatastore.extensiondata.moref.value
               
        }

        [System.XML.XMLElement]$xmlVnics = $XMLDoc.CreateElement("interfaces")
        $xmlRoot.appendChild($xmlVnics) | out-null
        foreach ( $VnicSpec in $Interface ) {

            $import = $xmlDoc.ImportNode(($VnicSpec), $true)
            $xmlVnics.AppendChild($import) | out-null

        }

        #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/4.0/edges"

        Write-Progress -activity "Creating Logical Router $Name"    
        $response = invoke-nsxwebrequest -method "post" -uri $URI -body $body
        Write-Progress -activity "Creating Logical Router $Name"  -completed
        $edgeId = $response.Headers.Location.split("/")[$response.Headers.Location.split("/").GetUpperBound(0)] 

        if ( $EnableHA ) {
            
            [System.XML.XMLElement]$xmlHA = $XMLDoc.CreateElement("highAvailability")
            Add-XmlElement -xmlRoot $xmlHA -xmlElementName "enabled" -xmlElementText "true"
            $body = $xmlHA.OuterXml
            $URI = "/api/4.0/edges/$edgeId/highavailability/config"
            Write-Progress -activity "Enable HA on Logical Router $Name"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Enable HA on Logical Router $Name" -completed

        }
        Get-NsxLogicalRouter -objectID $edgeId

    }
    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouter

function Remove-NsxLogicalRouter {

    <#
    .SYNOPSIS
    Deletes a Logical Router object.
    
    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    This cmdlet deletes the specified Logical Router object.
    
    .EXAMPLE
    
    Example1: Remove Logical Router LR1.
    PS C:\> Get-NsxLogicalRouter LR1 | Remove-NsxLogicalRouter

    Example2: No confirmation on delete.
    PS C:\> Get-NsxLogicalRouter LR1 | Remove-NsxLogicalRouter -confirm:$false
    
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouter $_ })]
            [System.Xml.XmlElement]$LogicalRouter,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true

    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Logical Router removal is permanent."
            $question = "Proceed with removal of Logical Router $($LogicalRouter.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            $URI = "/api/4.0/edges/$($LogicalRouter.Edgesummary.ObjectId)"
            Write-Progress -activity "Remove Logical Router $($LogicalRouter.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove Logical Router $($LogicalRouter.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouter

function Set-NsxLogicalRouterInterface {

    <#
    .SYNOPSIS
    Configures an existing NSX LogicalRouter interface.

    .DESCRIPTION
    NSX Logical Routers can host up to 8 uplink and 1000 internal interfaces, each of which 
    can be configured with multiple properties.  

    Logical Routers support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches, although connection to VLAN backed PortGroups is not a recommended 
    configuration.

    Use Set-NsxLogicalRouterInterface to overwrite the configuration of an existing
    interface.

    #>

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterInterface $_ })]
            [System.Xml.XmlElement]$Interface,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateSet ("internal","uplink")]
            [string]$Type,
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$ConnectedTo,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU=1500,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Connected=$true,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Confirm=$true   
    )

    begin {}
    process { 

        #Check if there is already configuration 
        if ( $confirm ) { 

            $message  = "Interface configuration will be overwritten."
            $question = "Proceed with reconfiguration for $($Interface.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            if ( $decision -eq 1 ) {
                return
            }
        }

        #generate the vnic XML 
        $vNicSpecParams = @{ 
            Index = $Interface.index 
            Name = $name 
            Type = $type 
            ConnectedTo = $connectedTo                      
            MTU = $MTU 
            Connected = $connected
        }
        if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $vNicSpecParams.Add("PrimaryAddress",$PrimaryAddress) }
        if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $vNicSpecParams.Add("SubnetPrefixLength",$SubnetPrefixLength) }
        if ( $PsBoundParameters.ContainsKey("SecondaryAddresses" )) { $vNicSpecParams.Add("SecondaryAddresses",$SecondaryAddresses) }

        $VnicSpec = New-NsxLogicalRouterInterfaceSpec @vNicSpecParams
        write-debug "$($MyInvocation.MyCommand.Name) : vNic Spec is $($VnicSpec.outerxml | format-xml) "

        #Construct the XML
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlVnics = $XMLDoc.CreateElement("interfaces")
        $import = $xmlDoc.ImportNode(($VnicSpec), $true)
        $xmlVnics.AppendChild($import) | out-null

        # #Do the post
        $body = $xmlVnics.OuterXml
        $URI = "/api/4.0/edges/$($Interface.logicalRouterId)/interfaces/?action=patch"
        Write-Progress -activity "Updating Logical Router interface configuration for interface $($Interface.Index)."
        invoke-nsxrestmethod -method "post" -uri $URI -body $body
        Write-progress -activity "Updating Logical Router interface configuration for interface $($Interface.Index)." -completed

    }

    end {}
}
Export-ModuleMember -Function Set-NsxLogicalRouterInterface

function New-NsxLogicalRouterInterface {

    <#
    .SYNOPSIS
    Configures an new NSX LogicalRouter interface.

    .DESCRIPTION
    NSX Logical Routers can host up to 8 uplink and 1000 internal interfaces, each of which 
    can be configured with multiple properties.  

    Logical Routers support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches, although connection to VLAN backed PortGroups is not a recommended 
    configuration.

    Use New-NsxLogicalRouterInterface to create a new Logical Router interface.

    #>

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouter $_ })]
            [System.Xml.XmlElement]$LogicalRouter,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateSet ("internal","uplink")]
            [string]$Type,
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$ConnectedTo,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU=1500,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Connected=$true,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Confirm=$true   
    )

    begin {}
    process { 

        #generate the vnic XML 
        $vNicSpecParams = @{ 
            Name = $name 
            Type = $type 
            ConnectedTo = $connectedTo                      
            MTU = $MTU 
            Connected = $connected
        }
        if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $vNicSpecParams.Add("PrimaryAddress",$PrimaryAddress) }
        if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $vNicSpecParams.Add("SubnetPrefixLength",$SubnetPrefixLength) }
        if ( $PsBoundParameters.ContainsKey("SecondaryAddresses" )) { $vNicSpecParams.Add("SecondaryAddresses",$SecondaryAddresses) }

        $VnicSpec = New-NsxLogicalRouterInterfaceSpec @vNicSpecParams
        write-debug "$($MyInvocation.MyCommand.Name) : vNic Spec is $($VnicSpec.outerxml | format-xml) "

        #Construct the XML
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlVnics = $XMLDoc.CreateElement("interfaces")
        $import = $xmlDoc.ImportNode(($VnicSpec), $true)
        $xmlVnics.AppendChild($import) | out-null

        # #Do the post
        $body = $xmlVnics.OuterXml
        $URI = "/api/4.0/edges/$($LogicalRouter.Id)/interfaces/?action=patch"
        Write-Progress -activity "Creating Logical Router interface."
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body
        Write-progress -activity "Creating Logical Router interface." -completed
        $response.interfaces
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterInterface
function Remove-NsxLogicalRouterInterface {

    <#
    .SYNOPSIS
    Deletes an NSX Logical router interface.

    .DESCRIPTION
    NSX Logical Routers can host up to 8 uplink and 1000 internal interfaces, each of which 
    can be configured with multiple properties.  

    Logical Routers support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches, although connection to VLAN backed PortGroups is not a recommended 
    configuration.

    Use Remove-NsxLogicalRouterInterface to remove an existing Logical Router Interface.
    
    #>

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterInterface $_ })]
            [System.Xml.XmlElement]$Interface,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Confirm=$true   
    )

    begin {
    }

    process { 

        if ( $confirm ) { 

            $message  = "Interface ($Interface.Name) will be deleted."
            $question = "Proceed with deletion of interface $($Interface.index)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            if ( $decision -eq 1 ) {
                return
            }
        }
        

        # #Do the delete
        $URI = "/api/4.0/edges/$($Interface.logicalRouterId)/interfaces/$($Interface.Index)"
        Write-Progress -activity "Deleting interface $($Interface.Index) on logical router $($Interface.logicalRouterId)."
        invoke-nsxrestmethod -method "delete" -uri $URI
        Write-progress -activity "Deleting interface $($Interface.Index) on logical router $($Interface.logicalRouterId)." -completed

    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterInterface

function Get-NsxLogicalRouterInterface {

    <#
    .SYNOPSIS
    Retrieves the specified interface configuration on a specified Logical Router.

    .DESCRIPTION
    NSX Logical Routers can host up to 8 uplink and 1000 internal interfaces, each of which 
    can be configured with multiple properties.  

    Logical Routers support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches, although connection to VLAN backed PortGroups is not a recommended 
    configuration.

    Use Get-NsxLogicalRouterInterface to retrieve the configuration of a interface.

    .EXAMPLE
    Get all Interfaces on a Logical Router.

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouter $_ })]
            [System.Xml.XmlElement]$LogicalRouter,
        [Parameter (Mandatory=$False,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$True,ParameterSetName="Index")]
            [ValidateRange(1,1000)]
            [int]$Index
    )
    
    begin {}

    process {     

        if ( -not ($PsBoundParameters.ContainsKey("Index") )) { 
            #All Interfaces on LR
            $URI = "/api/4.0/edges/$($LogicalRouter.Id)/interfaces/"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if ( $PsBoundParameters.ContainsKey("name") ) {
                $return = $response.interfaces.interface | ? { $_.name -eq $name }
                if ( $return ) { 
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$return.OwnerDocument) -xmlRoot $return -xmlElementName "logicalRouterId" -xmlElementText $($LogicalRouter.Id)
                }
            } 
            else {
                $return = $response.interfaces.interface
                foreach ( $interface in $return ) { 
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$interface.OwnerDocument) -xmlRoot $interface -xmlElementName "logicalRouterId" -xmlElementText $($LogicalRouter.Id)
                }
            }
        }
        else {

            #Just getting a single named Interface
            $URI = "/api/4.0/edges/$($LogicalRouter.Id)/interfaces/$Index"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $return = $response.interface
            if ( $return ) {
                Add-XmlElement -xmlDoc ([system.xml.xmldocument]$return.OwnerDocument) -xmlRoot $return -xmlElementName "logicalRouterId" -xmlElementText $($LogicalRouter.Id)
            }
        }
        $return
    }
    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterInterface



########
########
# ESG related functions

###Private functions

function New-NsxEdgeVnicAddressGroup {

    #Private function that Edge (ESG and LogicalRouter) VNIC creation leverages
    #To create valid address groups (primary and potentially secondary address) 
    #and netmask.

    #ToDo - Implement IP address and netmask validation

    param (
        [Parameter (Mandatory=$true)]
            [System.XML.XMLElement]$xmlAddressGroups,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullorEmpty()]
            [System.XML.XMLDocument]$xmlDoc,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [string[]]$SecondaryAddresses=@()

    )

    begin {}

    process {

        [System.XML.XMLElement]$xmlAddressGroup = $xmlDoc.CreateElement("addressGroup")
        $xmlAddressGroups.appendChild($xmlAddressGroup) | out-null
        Add-XmlElement -xmlRoot $xmlAddressGroup -xmlElementName "primaryAddress" -xmlElementText $PrimaryAddress
        Add-XmlElement -xmlRoot $xmlAddressGroup -xmlElementName "subnetPrefixLength" -xmlElementText $SubnetPrefixLength
        if ( $SecondaryAddresses ) { 
            [System.XML.XMLElement]$xmlSecondaryAddresses = $XMLDoc.CreateElement("secondaryAddresses")
            $xmlAddressGroup.appendChild($xmlSecondaryAddresses) | out-null
            foreach ($Address in $SecondaryAddresses) { 
                Add-XmlElement -xmlRoot $xmlSecondaryAddresses -xmlElementName "ipAddress" -xmlElementText $Address
            }
        }
    }

    end{}
}

###End Private functions

function New-NsxEdgeInterfaceSpec {

    <#
    .SYNOPSIS
    Creates a new NSX Edge Service Gateway interface Spec.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  In order to allow creation of 
    ESGs with an arbitrary number of interfaces, a unique spec for each 
    interface required must first be created.

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.
    
    .EXAMPLE

    PS C:\> $Uplink = New-NsxEdgeInterfaceSpec -Name Uplink_interface -Type 
        uplink -ConnectedTo (Get-NsxTransportZone | Get-NsxLogicalSwitch LS1) 
        -PrimaryAddress 192.168.0.1 -SubnetPrefixLength 24

    PS C:\> $Internal = New-NsxEdgeInterfaceSpec -Name Internal-interface -Type 
        internal -ConnectedTo (Get-NsxTransportZone | Get-NsxLogicalSwitch LS2) 
        -PrimaryAddress 10.0.0.1 -SubnetPrefixLength 24
    
    #>

    param (
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,9)]
            [int]$Index,
        [Parameter (Mandatory=$false)]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateSet ("internal","uplink","trunk")]
            [string]$Type,
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$ConnectedTo,
        [Parameter (Mandatory=$false)]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [string[]]$SecondaryAddresses=@(),
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU=1500,       
        [Parameter (Mandatory=$false)]
            [switch]$EnableProxyArp=$false,       
        [Parameter (Mandatory=$false)]
            [switch]$EnableSendICMPRedirects=$true,
        [Parameter (Mandatory=$false)]
            [switch]$Connected=$true 

    )

    begin {

        #toying with the idea of using dynamicParams for this, but decided on standard validation code for now.
        if ( ($Type -eq "trunk") -and ( $ConnectedTo -is [System.Xml.XmlElement])) { 
            #Not allowed to have a trunk interface connected to a Logical Switch.
            throw "Interfaces of type Trunk must be connected to a distributed port group."
        }

        if ( $Connected -and ( -not $connectedTo ) ) { 
            #Not allowed to be connected without a connected port group.
            throw "Interfaces that are connected must be connected to a distributed Portgroup or Logical Switch."
        }

        if (( $PsBoundParameters.ContainsKey("PrimaryAddress") -and ( -not $PsBoundParameters.ContainsKey("SubnetPrefixLength"))) -or 
            (( -not $PsBoundParameters.ContainsKey("PrimaryAddress")) -and  $PsBoundParameters.ContainsKey("SubnetPrefixLength"))) {

            #Not allowed to have subnet without primary or vice versa.
            throw "Interfaces with a Primary address must also specify a prefix length and vice versa."   
        }
                
    }
    process { 

        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlVnic = $XMLDoc.CreateElement("vnic")
        $xmlDoc.appendChild($xmlVnic) | out-null

        if ( $PsBoundParameters.ContainsKey("Name")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "name" -xmlElementText $Name }
        if ( $PsBoundParameters.ContainsKey("Index")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "index" -xmlElementText $Index }  
        if ( $PsBoundParameters.ContainsKey("Type")) { 
            Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "type" -xmlElementText $Type 
        }
        else {
            Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "type" -xmlElementText "internal" 

        }
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "mtu" -xmlElementText $MTU
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "enableProxyArp" -xmlElementText $EnableProxyArp
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "enableSendRedirects" -xmlElementText $EnableSendICMPRedirects
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "isConnected" -xmlElementText $Connected

        if ( $PsBoundParameters.ContainsKey("ConnectedTo")) { 
            switch ($ConnectedTo){

                { ($_ -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl]) -or ( $_ -is [VMware.VimAutomation.Vds.Impl.VDObjectImpl] ) }  { $PortGroupID = $_.ExtensionData.MoRef.Value }
                { $_ -is [System.Xml.XmlElement]} { $PortGroupID = $_.objectId }
            }  
            Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "portgroupId" -xmlElementText $PortGroupID
        }

        if ( $PsBoundParameters.ContainsKey("PrimaryAddress")) {
            #For now, only supporting one addressgroup - will refactor later
            [System.XML.XMLElement]$xmlAddressGroups = $XMLDoc.CreateElement("addressGroups")
            $xmlVnic.appendChild($xmlAddressGroups) | out-null
            $AddressGroupParameters = @{
                xmldoc = $xmlDoc 
                xmlAddressGroups = $xmlAddressGroups
            }

            if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $AddressGroupParameters.Add("PrimaryAddress",$PrimaryAddress) }
            if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $AddressGroupParameters.Add("SubnetPrefixLength",$SubnetPrefixLength) }
            if ( $PsBoundParameters.ContainsKey("SecondaryAddresses" )) { $AddressGroupParameters.Add("SecondaryAddresses",$SecondaryAddresses) }
             

            New-NsxEdgeVnicAddressGroup @AddressGroupParameters
        }

        $xmlVnic

    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeInterfaceSpec

function New-NsxEdgeSubInterfaceSpec {

    <#
    .SYNOPSIS
    Creates a new NSX Edge Service Gateway SubInterface Spec.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  In order to allow creation of 
    ESGs with an arbitrary number of interfaces, a unique spec for each 
    interface required must first be created.

    ESGs support Subinterfaces that specify either VLAN ID (VLAN Type) or  NSX
    Logical Switch/Distributed Port Group (Network Type).
    
    #>

    [CmdLetBinding(DefaultParameterSetName="None")]

    param (
        [Parameter (Mandatory=$true)]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateRange(1,4094)]
            [int]$TunnelId,
        [Parameter (Mandatory=$false,ParameterSetName="Network")]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$Network,
        [Parameter (Mandatory=$false,ParameterSetName="VLAN")]
            [ValidateRange(0,4094)]
            [int]$VLAN,
        [Parameter (Mandatory=$false)]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [string[]]$SecondaryAddresses=@(),
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU,              
        [Parameter (Mandatory=$false)]
            [switch]$EnableSendICMPRedirects,
        [Parameter (Mandatory=$false)]
            [switch]$Connected=$true 

    )

    begin {


        if (( $PsBoundParameters.ContainsKey("PrimaryAddress") -and ( -not $PsBoundParameters.ContainsKey("SubnetPrefixLength"))) -or 
            (( -not $PsBoundParameters.ContainsKey("PrimaryAddress")) -and  $PsBoundParameters.ContainsKey("SubnetPrefixLength"))) {

            #Not allowed to have subnet without primary or vice versa.
            throw "Interfaces with a Primary address must also specify a prefix length and vice versa."   
        }
                
    }
    process { 

        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlVnic = $XMLDoc.CreateElement("subInterface")
        $xmlDoc.appendChild($xmlVnic) | out-null

        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "name" -xmlElementText $Name 
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "tunnelId" -xmlElementText $TunnelId
        Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "isConnected" -xmlElementText $Connected

        if ( $PsBoundParameters.ContainsKey("MTU")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "mtu" -xmlElementText $MTU }
        if ( $PsBoundParameters.ContainsKey("EnableSendICMPRedirects")) { Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "enableSendRedirects" -xmlElementText $EnableSendICMPRedirects } 
        if ( $PsBoundParameters.ContainsKey("Network")) { 
            switch ($Network){

                { ($_ -is [VMware.VimAutomation.ViCore.Impl.V1.Host.Networking.DistributedPortGroupImpl]) -or ( $_ -is [VMware.VimAutomation.Vds.Impl.VDObjectImpl] ) }  { $PortGroupID = $_.ExtensionData.MoRef.Value }
                { $_ -is [System.Xml.XmlElement]} { $PortGroupID = $_.objectId }
            }  

            #Even though the element name is logicalSwitchId, subinterfaces support VDPortGroup as well as Logical Switch.
            Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "logicalSwitchId" -xmlElementText $PortGroupID
        }

        if ( $PsBoundParameters.ContainsKey("VLAN")) {

            Add-XmlElement -xmlRoot $xmlVnic -xmlElementName "vlanId" -xmlElementText $VLAN
        }


        if ( $PsBoundParameters.ContainsKey("PrimaryAddress")) {
            #For now, only supporting one addressgroup - will refactor later
            [System.XML.XMLElement]$xmlAddressGroups = $XMLDoc.CreateElement("addressGroups")
            $xmlVnic.appendChild($xmlAddressGroups) | out-null
            $AddressGroupParameters = @{
                xmldoc = $xmlDoc 
                xmlAddressGroups = $xmlAddressGroups
            }

            if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $AddressGroupParameters.Add("PrimaryAddress",$PrimaryAddress) }
            if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $AddressGroupParameters.Add("SubnetPrefixLength",$SubnetPrefixLength) }
            if ( $PsBoundParameters.ContainsKey("SecondaryAddresses" )) { $AddressGroupParameters.Add("SecondaryAddresses",$SecondaryAddresses) }
             
            New-NsxEdgeVnicAddressGroup @AddressGroupParameters
        }

        $xmlVnic

    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeSubInterfaceSpec

function Set-NsxEdgeInterface {

    <#
    .SYNOPSIS
    Conigures an NSX Edge Services Gateway Interface.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use Set-NsxEdgeInterface to change (including overwriting) the configuration of an
    interface.

    .EXAMPLE
    Get an interface, then update it.
    
    PS C:\>$interface = Get-NsxEdge testesg | Get-NsxEdgeInterface -Index 4

    PS C:\> $interface | Set-NsxEdgeInterface -Name "vNic4" -Type internal 
        -ConnectedTo $ls4 -PrimaryAddress $ip4 -SubnetPrefixLength 24

    #>

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeInterface $_ })]
            [System.Xml.XmlElement]$Interface,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateSet ("internal","uplink","trunk")]
            [string]$Type,
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$ConnectedTo,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [string[]]$SecondaryAddresses=@(),
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU=1500,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$EnableProxyArp=$false,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$EnableSendICMPRedirects=$true,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Connected=$true,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Confirm=$true   
    )

    begin {}
    process { 

        #Check if there is already configuration 
        if ( $confirm ) { 

            If ( ($Interface | get-member -memberType properties PortGroupID ) -or ( $Interface.addressGroups ) ) {

                $message  = "Interface $($Interface.Name) appears to already be configured.  Config will be overwritten."
                $question = "Proceed with reconfiguration for $($Interface.Name)?"

                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
                if ( $decision -eq 1 ) {
                    return
                }
            }
        }

        #generate the vnic XML 
        $vNicSpecParams = @{ 
            Index = $Interface.index 
            Name = $name 
            Type = $type 
            ConnectedTo = $connectedTo                      
            MTU = $MTU 
            EnableProxyArp = $EnableProxyArp
            EnableSendICMPRedirects = $EnableSendICMPRedirects 
            Connected = $connected
        }
        if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $vNicSpecParams.Add("PrimaryAddress",$PrimaryAddress) }
        if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $vNicSpecParams.Add("SubnetPrefixLength",$SubnetPrefixLength) }
        if ( $PsBoundParameters.ContainsKey("SecondaryAddresses" )) { $vNicSpecParams.Add("SecondaryAddresses",$SecondaryAddresses) }

        $VnicSpec = New-NsxEdgeInterfaceSpec @vNicSpecParams
        write-debug "$($MyInvocation.MyCommand.Name) : vNic Spec is $($VnicSpec.outerxml | format-xml) "

        #Construct the XML
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlVnics = $XMLDoc.CreateElement("vnics")
        $import = $xmlDoc.ImportNode(($VnicSpec), $true)
        $xmlVnics.AppendChild($import) | out-null

        # #Do the post
        $body = $xmlVnics.OuterXml
        $URI = "/api/4.0/edges/$($Interface.edgeId)/vnics/?action=patch"
        Write-Progress -activity "Updating Edge Services Gateway interface configuration for interface $($Interface.Index)."
        invoke-nsxrestmethod -method "post" -uri $URI -body $body
        Write-progress -activity "Updating Edge Services Gateway interface configuration for interface $($Interface.Index)." -completed

    }

    end {}
}
Export-ModuleMember -Function Set-NsxEdgeInterface

function Clear-NsxEdgeInterface {

    <#
    .SYNOPSIS
    Clears the configuration on an NSX Edge Services Gateway interface.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  

    ESGs support itnerfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use Clear-NsxEdgeInterface to set the configuration of an interface back to default 
    (disconnected, not attached to any portgroup, and no defined addressgroup).
    
    .EXAMPLE
    Get an interface and then clear its configuration.

    PS C:\> $interface = Get-NsxEdge $name | Get-NsxEdgeInterface "vNic4"

    PS C:\> $interface | Clear-NsxEdgeInterface -confirm:$false

    #>

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeInterface $_ })]
            [System.Xml.XmlElement]$Interface,       
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Confirm=$true   

    )

    begin {
    }

    process { 

        if ( $confirm ) { 

            $message  = "Interface ($Interface.Name) config will be cleared."
            $question = "Proceed with interface reconfiguration for interface $($interface.index)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            if ( $decision -eq 1 ) {
                return
            }
        }
        

        # #Do the delete
        $URI = "/api/4.0/edges/$($interface.edgeId)/vnics/$($interface.Index)"
        Write-Progress -activity "Clearing Edge Services Gateway interface configuration for interface $($interface.Index)."
        invoke-nsxrestmethod -method "delete" -uri $URI
        Write-progress -activity "Clearing Edge Services Gateway interface configuration for interface $($interface.Index)." -completed

    }

    end {}
}
Export-ModuleMember -Function Clear-NsxEdgeInterface

function Get-NsxEdgeInterface {

    <#
    .SYNOPSIS
    Retrieves the specified interface configuration on a specified Edge Services 
    Gateway.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use Get-NsxEdgeInterface to retrieve the configuration of an interface.

    .EXAMPLE
    Get all interface configuration for ESG named EsgTest
    PS C:\> Get-NsxEdge EsgTest | Get-NsxEdgeInterface

    .EXAMPLE
    Get interface configuration for interface named vNic4 on ESG named EsgTest
    PS C:\> Get-NsxEdge EsgTest | Get-NsxEdgeInterface vNic4


    .EXAMPLE
    Get interface configuration for interface number 4 on ESG named EsgTest
    PS C:\> Get-NsxEdge EsgTest | Get-NsxEdgeInterface -index 4

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-Edge $_ })]
            [System.Xml.XmlElement]$Edge,
        [Parameter (Mandatory=$False,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$True,ParameterSetName="Index")]
            [ValidateRange(0,9)]
            [int]$Index
    )
    
    begin {}

    process {     

        if ( -not ($PsBoundParameters.ContainsKey("Index") )) { 
            #All interfaces on Edge
            $URI = "/api/4.0/edges/$($Edge.Id)/vnics/"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if ( $PsBoundParameters.ContainsKey("name") ) {
                $return = $response.vnics.vnic | ? { $_.name -eq $name }
                Add-XmlElement -xmlDoc ([system.xml.xmldocument]$return.OwnerDocument) -xmlRoot $return -xmlElementName "edgeId" -xmlElementText $($Edge.Id)
            } 
            else {
                $return = $response.vnics.vnic
                foreach ( $vnic in $return ) { 
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$vnic.OwnerDocument) -xmlRoot $vnic -xmlElementName "edgeId" -xmlElementText $($Edge.Id)
                }
            }
        }
        else {

            #Just getting a single named vNic
            $URI = "/api/4.0/edges/$($Edge.Id)/vnics/$Index"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $return = $response.vnic
            Add-XmlElement -xmlDoc ([system.xml.xmldocument]$return.OwnerDocument) -xmlRoot $return -xmlElementName "edgeId" -xmlElementText $($Edge.Id)
        }
        $return
    }
    end {}
}
Export-ModuleMember -Function Get-NsxEdgeInterface

function New-NsxEdgeSubInterface {

    <#
    .SYNOPSIS
    Adds a new subinterface to an existing NSX Edge Services Gateway trunk mode 
    interface.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use New-NsxEdgeSubInterface to add a new subinterface.

    .EXAMPLE
    Get an NSX Edge interface and configure a new subinterface in VLAN mode.

    PS C:\> $trunk = Get-NsxEdge $name | Get-NsxEdgeInterface "vNic3"

    PS C:\> $trunk | New-NsxEdgeSubinterface  -Name "sub1" -PrimaryAddress $ip5 
        -SubnetPrefixLength 24 -TunnelId 1 -Vlan 123

    .EXAMPLE
    Get an NSX Edge interface and configure a new subinterface in Network mode.

    PS C:\> $trunk = Get-NsxEdge $name | Get-NsxEdgeInterface "vNic3"

    PS C:\> $trunk | New-NsxEdgeSubinterface  -Name "sub1" -PrimaryAddress $ip5 
        -SubnetPrefixLength 24 -TunnelId 1 -Network $LS2
    
    #>

    [CmdLetBinding(DefaultParameterSetName="None")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeInterface $_ })]
            [System.Xml.XmlElement]$Interface,
        [Parameter (Mandatory=$true)]
            [ValidateRange(1,4094)]
            [int]$TunnelId,
        [Parameter (Mandatory=$false,ParameterSetName="Network")]
            [ValidateScript({ Validate-LogicalSwitchOrDistributedPortGroup $_ })]
            [object]$Network,
        [Parameter (Mandatory=$false,ParameterSetName="VLAN")]
            [ValidateRange(0,4094)]
            [int]$VLAN,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$PrimaryAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$SubnetPrefixLength,       
        [Parameter (Mandatory=$false)]
            [string[]]$SecondaryAddresses=@(),
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,9128)]
            [int]$MTU,             
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$EnableSendICMPRedirects,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$Connected=$true
    )


    #Validate interfaceindex is trunk
    if ( -not $Interface.type -eq 'trunk' ) {
        throw "Specified interface $($interface.Name) is of type $($interface.type) but must be of type trunk to host a subinterface. "
    }

    #Remove our crap so the put doesnt barf later.
    $EdgeId = $interface.edgeId
    $NodeToRemove = $interface.SelectSingleNode("descendant::edgeId")
    write-debug "$($MyInvocation.MyCommand.Name) : XPath query for node to delete returned $($NodetoRemove.OuterXml | format-xml)"
    $interface.RemoveChild($NodeToRemove) | out-null

    #Get or create the subinterfaces node. 
    [System.XML.XMLDocument]$xmlDoc = $interface.OwnerDocument
    if ( $interface | get-member -memberType Properties -Name subInterfaces) { 
        [System.XML.XMLElement]$xmlSubInterfaces = $interface.subInterfaces
    }
    else {
        [System.XML.XMLElement]$xmlSubInterfaces = $xmlDoc.CreateElement("subInterfaces")
        $interface.AppendChild($xmlSubInterfaces) | out-null
    }

    #generate the vnic XML 
    $vNicSpecParams = @{    
        TunnelId = $TunnelId 
        Connected = $connected
        Name = $Name
    }

    switch ($psCmdlet.ParameterSetName) {

        "Network" { if ( $PsBoundParameters.ContainsKey("Network" )) { $vNicSpecParams.Add("Network",$Network) } }
        "VLAN" { if ( $PsBoundParameters.ContainsKey("VLAN" )) { $vNicSpecParams.Add("VLAN",$VLAN) } }
        "None" {}
        Default { throw "An invalid parameterset was found.  This should never happen." }
    }

    if ( $PsBoundParameters.ContainsKey("PrimaryAddress" )) { $vNicSpecParams.Add("PrimaryAddress",$PrimaryAddress) }
    if ( $PsBoundParameters.ContainsKey("SubnetPrefixLength" )) { $vNicSpecParams.Add("SubnetPrefixLength",$SubnetPrefixLength) }
    if ( $PsBoundParameters.ContainsKey("SecondaryAddresses" )) { $vNicSpecParams.Add("SecondaryAddresses",$SecondaryAddresses) }
    if ( $PsBoundParameters.ContainsKey("MTU" )) { $vNicSpecParams.Add("MTU",$MTU) }
    if ( $PsBoundParameters.ContainsKey("EnableSendICMPRedirects" )) { $vNicSpecParams.Add("EnableSendICMPRedirects",$EnableSendICMPRedirects) }

    $VnicSpec = New-NsxEdgeSubInterfaceSpec @vNicSpecParams
    write-debug "$($MyInvocation.MyCommand.Name) : vNic Spec is $($VnicSpec.outerxml | format-xml) "
    $import = $xmlDoc.ImportNode(($VnicSpec), $true)
    $xmlSubInterfaces.AppendChild($import) | out-null

    # #Do the post
    $body = $Interface.OuterXml
    $URI = "/api/4.0/edges/$($EdgeId)/vnics/$($Interface.Index)"
    Write-Progress -activity "Updating Edge Services Gateway interface configuration for $($interface.Name)."
    invoke-nsxrestmethod -method "put" -uri $URI -body $body
    Write-progress -activity "Updating Edge Services Gateway interface configuration for $($interface.Name)." -completed
}
Export-ModuleMember -Function New-NsxEdgeSubInterface

function Remove-NsxEdgeSubInterface {

    <#
    .SYNOPSIS
    Removes the specificed subinterface from an NSX Edge Services Gateway  
    interface.

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use Remove-NsxEdgeSubInterface to remove a subinterface configuration from 
    and ESG trunk interface.  

    .EXAMPLE
    Get a subinterface and then remove it.

    PS C:\> $interface =  Get-NsxEdge $name | Get-NsxEdgeInterface "vNic3" 

    PS C:\> $interface | Get-NsxEdgeSubInterface "sub1" | Remove-NsxEdgeSubinterface 
 
    
    #>

    [CmdLetBinding(DefaultParameterSetName="None")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeSubInterface $_ })]
            [System.Xml.XmlElement]$Subinterface,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true

    )

    if ( $confirm ) { 

        $message  = "Interface ($Subinterface.Name) will be removed."
        $question = "Proceed with interface reconfiguration for interface $($Subinterface.index)?"

        $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
        $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
        $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

        $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        if ( $decision -eq 1 ) {
            return
        }
    }

    #Get the vnic xml
    $ParentVnic = $(Get-NsxEdge -objectId $SubInterface.edgeId).vnics.vnic | ? { $_.index -eq $subInterface.vnicId }

    #Remove the node using xpath query.
    $NodeToRemove = $ParentVnic.subInterfaces.SelectSingleNode("descendant::subInterface[index=$($subInterface.Index)]")
    write-debug "$($MyInvocation.MyCommand.Name) : XPath query for node to delete returned $($NodetoRemove.OuterXml | format-xml)"
    $ParentVnic.Subinterfaces.RemoveChild($NodeToRemove) | out-null

    #Put the modified VNIC xml
    $body = $ParentVnic.OuterXml
    $URI = "/api/4.0/edges/$($SubInterface.edgeId)/vnics/$($ParentVnic.Index)"
    Write-Progress -activity "Updating Edge Services Gateway interface configuration for interface $($ParentVnic.Name)."
    invoke-nsxrestmethod -method "put" -uri $URI -body $body
    Write-progress -activity "Updating Edge Services Gateway interface configuration for interface $($ParentVnic.Name)." -completed
}
Export-ModuleMember -Function Remove-NsxEdgeSubInterface

function Get-NsxEdgeSubInterface {

    <#
    .SYNOPSIS
    Retrieves the subinterface configuration for the specified interface

    .DESCRIPTION
    NSX ESGs can host up to 10 interfaces and up to 200 subinterfaces, each of which 
    can be configured with multiple properties.  

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use Get-NsxEdgeSubInterface to retrieve the subinterface configuration of an 
    interface.
    
    .EXAMPLE
    Get an NSX Subinterface called sub1 from any interface on esg testesg

    PS C:\> Get-NsxEdge testesg | Get-NsxEdgeInterface | 
        Get-NsxEdgeSubInterface "sub1"


    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeInterface $_ })]
            [System.Xml.XmlElement]$Interface,   
        [Parameter (Mandatory=$False,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$True,ParameterSetName="Index")]
            [ValidateRange(10,200)]
            [int]$Index
    )
    
    begin {}

    process {    

        #Not throwing error if no subinterfaces defined.    
        If ( $interface | get-member -name subInterfaces -Membertype Properties ) {  

            if ($PsBoundParameters.ContainsKey("Index")) { 

                $subint = $Interface.subInterfaces.subinterface | ? { $_.index -eq $Index }
                if ( $subint ) {
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$Interface.OwnerDocument) -xmlRoot $subint -xmlElementName "edgeId" -xmlElementText $($Interface.edgeId)
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$Interface.OwnerDocument) -xmlRoot $subint -xmlElementName "vnicId" -xmlElementText $($Interface.index)
                    $subint
                }
            }
            elseif ( $PsBoundParameters.ContainsKey("name")) {
                    
                $subint = $Interface.subInterfaces.subinterface | ? { $_.name -eq $name }
                if ($subint) { 
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$Interface.OwnerDocument) -xmlRoot $subint -xmlElementName "edgeId" -xmlElementText $($Interface.edgeId)
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$Interface.OwnerDocument) -xmlRoot $subint -xmlElementName "vnicId" -xmlElementText $($Interface.index)
                    $subint
                }
            } 
            else {
                #All Subinterfaces on interface
                foreach ( $subint in $Interface.subInterfaces.subInterface ) {
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$Interface.OwnerDocument) -xmlRoot $subint -xmlElementName "edgeId" -xmlElementText $($Interface.edgeId)
                    Add-XmlElement -xmlDoc ([system.xml.xmldocument]$Interface.OwnerDocument) -xmlRoot $subint -xmlElementName "vnicId" -xmlElementText $($Interface.index)
                    $subInt
                }
            }
        }
    }
    end {}
}
Export-ModuleMember -Function Get-NsxEdgeSubInterface

function Get-NsxEdge {

    <#
    .SYNOPSIS
    Retrieves an NSX Edge Service Gateway Object.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    
    .EXAMPLE
    PS C:\>  Get-NsxEdge

    #>


    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ParameterSetName="objectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name

    )

    $pagesize = 10         
    switch ( $psCmdlet.ParameterSetName ) {

        "Name" { 
            $URI = "/api/4.0/edges?pageSize=$pagesize&startIndex=00" 
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            
            #Edge summary XML is returned as paged data, means we have to handle it.  
            #Then we have to query for full information on a per edge basis.
            $edgesummaries = @()
            $edges = @()
            $itemIndex =  0
            $startingIndex = 0 
            $pagingInfo = $response.pagedEdgeList.edgePage.pagingInfo
            
            if ( [int]$paginginfo.totalCount -ne 0 ) {
                 write-debug "$($MyInvocation.MyCommand.Name) : ESG count non zero"

                do {
                    write-debug "$($MyInvocation.MyCommand.Name) : In paging loop. PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"

                    while (($itemindex -lt ([int]$paginginfo.pagesize + $startingIndex)) -and ($itemIndex -lt [int]$paginginfo.totalCount )) {
            
                        write-debug "$($MyInvocation.MyCommand.Name) : In Item Processing Loop: ItemIndex: $itemIndex"
                        write-debug "$($MyInvocation.MyCommand.Name) : $(@($response.pagedEdgeList.edgePage.edgeSummary)[($itemIndex - $startingIndex)].objectId)"
                    
                        #Need to wrap the edgesummary prop of the datapage in case we get exactly 1 item - 
                        #which powershell annoyingly unwraps to a single xml element rather than an array...
                        $edgesummaries += @($response.pagedEdgeList.edgePage.edgeSummary)[($itemIndex - $startingIndex)]
                        $itemIndex += 1 
                    }  
                    write-debug "$($MyInvocation.MyCommand.Name) : Out of item processing - PagingInfo: PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"
                    if ( [int]$paginginfo.totalcount -gt $itemIndex) {
                        write-debug "$($MyInvocation.MyCommand.Name) : PagingInfo: PageSize: $($pagingInfo.PageSize), StartIndex: $($paginginfo.startIndex), TotalCount: $($paginginfo.totalcount)"
                        $startingIndex += $pagesize
                        $URI = "/api/4.0/edges?pageSize=$pagesize&startIndex=$startingIndex"
                
                        $response = invoke-nsxrestmethod -method "get" -uri $URI
                        $pagingInfo = $response.pagedEdgeList.edgePage.pagingInfo
                    

                    } 
                } until ( [int]$paginginfo.totalcount -le $itemIndex )    
                write-debug "$($MyInvocation.MyCommand.Name) : Completed page processing: ItemIndex: $itemIndex"
            }

            #What we got here is...failure to communicate!  In order to get full detail, we have to requery for each edgeid.
            #But... there is information in the SUmmary that isnt in the full detail.  So Ive decided to add the summary as a node 
            #to the returned edge detail. 

            foreach ($edgesummary in $edgesummaries) {

                $URI = "/api/4.0/edges/$($edgesummary.objectID)" 
                $response = invoke-nsxrestmethod -method "get" -uri $URI
                $import = $response.edge.ownerDocument.ImportNode($edgesummary, $true)
                $response.edge.appendChild($import) | out-null                
                $edges += $response.edge

            }

            if ( $name ) { 
                $edges | ? { $_.Type -eq 'gatewayServices' } | ? { $_.name -eq $name }

            } else {
                $edges | ? { $_.Type -eq 'gatewayServices' }

            }

        }

        "objectId" { 

            $URI = "/api/4.0/edges/$objectId" 
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $edge = $response.edge
            $URI = "/api/4.0/edges/$objectId/summary" 
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $import = $edge.ownerDocument.ImportNode($($response.edgeSummary), $true)
            $edge.AppendChild($import) | out-null
            $edge

        }
    }
}
Export-ModuleMember -Function Get-NsxEdge

function New-NsxEdge {

    <#
    .SYNOPSIS
    Creates a new NSX Edge Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    PowerCLI cmdlets such as Get-VDPortGroup and Get-Datastore require a valid
    PowerCLI session.
    
    .EXAMPLE
    Create interface specifications first for each interface that you want on the ESG

    PS C:\> $vnic0 = New-NsxEdgeInterfaceSpec -Index 0 -Name Uplink -Type Uplink 
        -ConnectedTo (Get-VDPortgroup Corp) -PrimaryAddress "1.1.1.2" 
        -SubnetPrefixLength 24

    PS C:\> $vnic1 = New-NsxEdgeInterfaceSpec -Index 1 -Name Internal -Type Uplink 
        -ConnectedTo $LogicalSwitch1 -PrimaryAddress "2.2.2.1" 
        -SecondaryAddresses "2.2.2.2" -SubnetPrefixLength 24

    Then create the Edge Services Gateway
    PS C:\> New-NsxEdge -name DMZ_Edge_2 
        -Cluster (get-cluster Cluster1) -Datastore (get-datastore Datastore1) 
        -Interface $vnic0,$vnic1 -Password 'Pass'

    #>

    param (
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true,ParameterSetName="ResourcePool")]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ResourcePoolImpl]$ResourcePool,
        [Parameter (Mandatory=$true,ParameterSetName="Cluster")]
            [ValidateScript({
                if ( $_ -eq $null ) { throw "Must specify Cluster."}
                if ( -not $_.DrsEnabled ) { throw "Cluster is not DRS enabled."}
                $true
            })]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.ClusterImpl]$Cluster,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.DatastoreImpl]$Datastore,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [String]$Password,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$EnableHA=$false,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.DatastoreManagement.DatastoreImpl]$HADatastore=$datastore,
        [Parameter (Mandatory=$false)]
            [ValidateSet ("compact","large","xlarge","quadlarge")]
            [string]$FormFactor="compact",
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.FolderImpl]$VMFolder,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [String]$Tenant,
         [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [String]$PrimaryDNSServer,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [String]$SecondaryDNSServer,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [String]$DNSDomainName,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$EnableSSH=$false,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$AutoGenerateRules=$true,
       [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-EdgeInterfaceSpec $_ })]
            [System.Xml.XmlElement[]]$Interface       
    )

    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("edge")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "type" -xmlElementText "gatewayServices"
        if ( $Tenant ) { Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "tenant" -xmlElementText $Tenant}


        [System.XML.XMLElement]$xmlAppliances = $XMLDoc.CreateElement("appliances")
        $xmlRoot.appendChild($xmlAppliances) | out-null
        
        switch ($psCmdlet.ParameterSetName){

            "Cluster"  { $ResPoolId = $($cluster | get-resourcepool | ? { $_.parent.id -eq $cluster.id }).extensiondata.moref.value }
            "ResourcePool"  { $ResPoolId = $ResourcePool.extensiondata.moref.value }

        }

        Add-XmlElement -xmlRoot $xmlAppliances -xmlElementName "applianceSize" -xmlElementText $FormFactor

        [System.XML.XMLElement]$xmlAppliance = $XMLDoc.CreateElement("appliance")
        $xmlAppliances.appendChild($xmlAppliance) | out-null
        Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "resourcePoolId" -xmlElementText $ResPoolId
        Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "datastoreId" -xmlElementText $datastore.extensiondata.moref.value
        if ( $VMFolder ) { Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "vmFolderId" -xmlElementText $VMFolder.extensiondata.moref.value}

        if ( $EnableHA ) {
            [System.XML.XMLElement]$xmlAppliance = $XMLDoc.CreateElement("appliance")
            $xmlAppliances.appendChild($xmlAppliance) | out-null
            Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "resourcePoolId" -xmlElementText $ResPoolId
            Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "datastoreId" -xmlElementText $HAdatastore.extensiondata.moref.value
            if ( $VMFolder ) { Add-XmlElement -xmlRoot $xmlAppliance -xmlElementName "vmFolderId" -xmlElementText $VMFolder.extensiondata.moref.value}
               
        }

        [System.XML.XMLElement]$xmlVnics = $XMLDoc.CreateElement("vnics")
        $xmlRoot.appendChild($xmlVnics) | out-null
        foreach ( $VnicSpec in $Interface ) {

            $import = $xmlDoc.ImportNode(($VnicSpec), $true)
            $xmlVnics.AppendChild($import) | out-null

        }

        # #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/4.0/edges"
        Write-Progress -activity "Creating Edge Services Gateway $Name"    
        $response = invoke-nsxwebrequest -method "post" -uri $URI -body $body
        Write-progress -activity "Creating Edge Services Gateway $Name" -completed
        $edgeId = $response.Headers.Location.split("/")[$response.Headers.Location.split("/").GetUpperBound(0)] 

        if ( $EnableHA ) {
            
            [System.XML.XMLElement]$xmlHA = $XMLDoc.CreateElement("highAvailability")
            Add-XmlElement -xmlRoot $xmlHA -xmlElementName "enabled" -xmlElementText "true"
            $body = $xmlHA.OuterXml
            $URI = "/api/4.0/edges/$edgeId/highavailability/config"
            
            Write-Progress -activity "Enable HA on edge $Name"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Enable HA on edge $Name" -completed

        }
        Get-NsxEdge -objectID $edgeId

    }
    end {}
}
Export-ModuleMember -Function New-NsxEdge

function Set-NsxEdge {

    <#
    .SYNOPSIS
    Configures an existing NSX Edge Services Gateway Raw configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs support interfaces connected to either VLAN backed port groups or NSX
    Logical Switches.

    Use the Set-NsxEdge to perform updates to the Raw XML config for an ESG
    to enable basic support for manipulating Edge features that arent supported
    by specific PowerNSX cmdlets.

    .EXAMPLE
    Disable the Edge Firewall on ESG Edge01

    PS C:\> $edge = Get-NsxEdge Edge01
    PS C:\> $edge.features.firewall.enabled = "false"
    PS C:\> $edge | Set-NsxEdge
    
    #>

    [CmdletBinding()]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-Edge $_ })]
            [System.Xml.XmlElement]$Edge,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true
    )
    
    begin {

    }

    process {

            
        #Clone the Edge Element so we can modify without barfing up the source object.
        $_Edge = $Edge.CloneNode($true)

        #Remove EdgeSummary...
        $edgeSummary = $_Edge.SelectSingleNode('descendant::edgeSummary')
        if ( $edgeSummary ) {
            $_Edge.RemoveChild($edgeSummary) | out-null
        }

        $URI = "/api/4.0/edges/$($_Edge.Id)"
        $body = $_Edge.OuterXml     
        
        if ( $confirm ) { 
            $message  = "Edge Services Gateway update will modify existing Edge configuration."
            $question = "Proceed with Update of Edge Services Gateway $($Edge.Name)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($Edge.Name)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($Edge.Name)" -completed
            Get-NsxEdge -objectId $($Edge.Id)
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxEdge

function Remove-NsxEdge {

    <#
    .SYNOPSIS
    Removes an existing NSX Edge Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    This cmdlet removes the specified ESG. 
    .EXAMPLE
   
    PS C:\> Get-NsxEdge TestESG | Remove-NsxEdge
        -confirm:$false
    
    #>
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-Edge $_ })]
            [System.Xml.XmlElement]$Edge,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true

    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Edge Services Gateway removal is permanent."
            $question = "Proceed with removal of Edge Services Gateway $($Edge.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            $URI = "/api/4.0/edges/$($Edge.Edgesummary.ObjectId)"
            Write-Progress -activity "Remove Edge Services Gateway $($Edge.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove Edge Services Gateway $($Edge.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdge

#########
#########
# Edge Routing related functions

function Set-NsxEdgeRouting {
    
    <#
    .SYNOPSIS
    Configures global routing configuration of an existing NSX Edge Services 
    Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Set-NsxEdgeRouting cmdlet configures the global routing configuration of
    the specified Edge Services Gateway.
    
    .EXAMPLE
    Configure the default route of the ESG
    
    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -DefaultGatewayVnic 0 -DefaultGatewayAddress 10.0.0.101

    .EXAMPLE
    Enable ECMP
    
    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -EnableECMP
    

    .EXAMPLE
    Enable OSPF

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -EnableOSPF -RouterId 1.1.1.1

    .EXAMPLE
    Enable BGP
    
    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdge | Get-NsxEdgeRouting | Set-NsxEdgeRouting -EnableBGP -RouterId 1.1.1.1 -LocalAS 1234

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Set-NsxEdgeRouting -EnableOspfRouteRedistribution:$false -Confirm:$false

    Disable OSPF Route Redistribution without confirmation.
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$EnableOspf,
        [Parameter (Mandatory=$False)]
            [switch]$EnableBgp,
        [Parameter (Mandatory=$False)]
            [IpAddress]$RouterId,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,65535)]
            [int]$LocalAS,
        [Parameter (Mandatory=$False)]
            [switch]$EnableEcmp,
        [Parameter (Mandatory=$False)]
            [switch]$EnableOspfRouteRedistribution,
        [Parameter (Mandatory=$False)]
            [switch]$EnableBgpRouteRedistribution,
        [Parameter (Mandatory=$False)]
            [switch]$EnableLogging,
        [Parameter (Mandatory=$False)]
            [ValidateSet("emergency","alert","critical","error","warning","notice","info","debug")]
            [string]$LogLevel,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,200)]
            [int]$DefaultGatewayVnic,        
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,9128)]
            [int]$DefaultGatewayMTU,        
        [Parameter (Mandatory=$False)]
            [string]$DefaultGatewayDescription,       
        [Parameter (Mandatory=$False)]
            [ipAddress]$DefaultGatewayAddress,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,255)]
            [int]$DefaultGatewayAdminDistance        

    )
    
    begin {

    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('EnableOSPF') -or $PsBoundParameters.ContainsKey('EnableBGP') ) { 
            $xmlGlobalConfig = $_EdgeRouting.routingGlobalConfig
            $xmlRouterId = $xmlGlobalConfig.SelectSingleNode('descendant::routerId')
            if ( $EnableOSPF -or $EnableBGP ) {
                if ( -not ($xmlRouterId -or $PsBoundParameters.ContainsKey("RouterId"))) {
                    #Existing config missing and no new value set...
                    throw "RouterId must be configured to enable dynamic routing"
                }

                if ($PsBoundParameters.ContainsKey("RouterId")) {
                    #Set Routerid...
                    if ($xmlRouterId) {
                        $xmlRouterId = $RouterId.IPAddresstoString
                    }
                    else{
                        Add-XmlElement -xmlRoot $xmlGlobalConfig -xmlElementName "routerId" -xmlElementText $RouterId.IPAddresstoString
                    }
                }
            }
        }

        if ( $PsBoundParameters.ContainsKey('EnableOSPF')) { 
            $ospf = $_EdgeRouting.SelectSingleNode('descendant::ospf') 
            if ( -not $ospf ) {
                #ospf node does not exist.
                [System.XML.XMLElement]$ospf = $_EdgeRouting.ownerDocument.CreateElement("ospf")
                $_EdgeRouting.appendChild($ospf) | out-null
            }

            if ( $ospf.SelectSingleNode('descendant::enabled')) {
                #Enabled element exists.  Update it.
                $ospf.enabled = $EnableOSPF.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $ospf -xmlElementName "enabled" -xmlElementText $EnableOSPF.ToString().ToLower()
            }
        
        }

        if ( $PsBoundParameters.ContainsKey('EnableBGP')) {

            $bgp = $_EdgeRouting.SelectSingleNode('descendant::bgp') 

            if ( -not $bgp ) {
                #bgp node does not exist.
                [System.XML.XMLElement]$bgp = $_EdgeRouting.ownerDocument.CreateElement("bgp")
                $_EdgeRouting.appendChild($bgp) | out-null
            }

            if ( $bgp.SelectSingleNode('descendant::enabled')) {
                #Enabled element exists.  Update it.
                $bgp.enabled = $EnableBGP.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $bgp -xmlElementName "enabled" -xmlElementText $EnableBGP.ToString().ToLower()
            }

            if ( $PsBoundParameters.ContainsKey("LocalAS")) { 
                if ( $bgp.SelectSingleNode('descendant::localAS')) {
                #LocalAS element exists, update it.
                    $bgp.localAS = $LocalAS.ToString()
                }
                else {
                    #LocalAS element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "localAS" -xmlElementText $LocalAS.ToString()
                }
            }
            elseif ( (-not ( $bgp.SelectSingleNode('descendant::localAS')) -and $EnableBGP  )) {
                throw "Existing configuration has no Local AS number specified.  Local AS must be set to enable BGP."
            }
            

        }

        if ( $PsBoundParameters.ContainsKey("EnableECMP")) { 
            $_EdgeRouting.routingGlobalConfig.ecmp = $EnableECMP.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("EnableOspfRouteRedistribution")) { 

            $_EdgeRouting.ospf.redistribution.enabled = $EnableOspfRouteRedistribution.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("EnableBgpRouteRedistribution")) { 
            if ( -not $_EdgeRouting.SelectSingleNode('child::bgp/redistribution/enabled') ) {
                throw "BGP must have been configured at least once to enable or disable BGP route redistribution.  Enable BGP and try again."
            }

            $_EdgeRouting.bgp.redistribution.enabled = $EnableBgpRouteRedistribution.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("EnableLogging")) { 
            $_EdgeRouting.routingGlobalConfig.logging.enable = $EnableLogging.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("LogLevel")) { 
            $_EdgeRouting.routingGlobalConfig.logging.logLevel = $LogLevel.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("DefaultGatewayVnic") -or $PsBoundParameters.ContainsKey("DefaultGatewayAddress") -or 
            $PsBoundParameters.ContainsKey("DefaultGatewayDescription") -or $PsBoundParameters.ContainsKey("DefaultGatewayMTU") -or
            $PsBoundParameters.ContainsKey("DefaultGatewayAdminDistance") ) { 

            #Check for and create if required the defaultRoute element. first.
            if ( -not $_EdgeRouting.staticRouting.SelectSingleNode('descendant::defaultRoute')) {
                #defaultRoute element does not exist
                $defaultRoute = $_EdgeRouting.ownerDocument.CreateElement('defaultRoute')
                $_EdgeRouting.staticRouting.AppendChild($defaultRoute) | out-null
            }
            else {
                #defaultRoute element exists
                $defaultRoute = $_EdgeRouting.staticRouting.defaultRoute
            }

            if ( $PsBoundParameters.ContainsKey("DefaultGatewayVnic") ) { 
                if ( -not $defaultRoute.SelectSingleNode('descendant::vnic')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "vnic" -xmlElementText $DefaultGatewayVnic.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.vnic = $DefaultGatewayVnic.ToString()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultGatewayAddress") ) { 
                if ( -not $defaultRoute.SelectSingleNode('descendant::gatewayAddress')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "gatewayAddress" -xmlElementText $DefaultGatewayAddress.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.gatewayAddress = $DefaultGatewayAddress.ToString()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultGatewayDescription") ) { 
                if ( -not $defaultRoute.SelectSingleNode('descendant::description')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "description" -xmlElementText $DefaultGatewayDescription
                }
                else {
                    #element exists
                    $defaultRoute.description = $DefaultGatewayDescription
                }
            }
            if ( $PsBoundParameters.ContainsKey("DefaultGatewayMTU") ) { 
                if ( -not $defaultRoute.SelectSingleNode('descendant::mtu')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "mtu" -xmlElementText $DefaultGatewayMTU.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.mtu = $DefaultGatewayMTU.ToString()
                }
            }
            if ( $PsBoundParameters.ContainsKey("DefaultGatewayAdminDistance") ) { 
                if ( -not $defaultRoute.SelectSingleNode('descendant::adminDistance')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "adminDistance" -xmlElementText $DefaultGatewayAdminDistance.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.adminDistance = $DefaultGatewayAdminDistance.ToString()
                }
            }
        }


        $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
        $body = $_EdgeRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
            $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxEdgeRouting

function Get-NsxEdgeRouting {
    
    <#
    .SYNOPSIS
    Retreives routing configuration for the spcified NSX Edge Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeRouting cmdlet retreives the routing configuration of
    the specified Edge Services Gateway.
    
    .EXAMPLE
    Get routing configuration for the ESG Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-Edge $_ })]
            [System.Xml.XmlElement]$Edge
    )
    
    begin {

    }

    process {
    
        #We append the Edge-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        $_EdgeRouting = $Edge.features.routing.CloneNode($True)
        Add-XmlElement -xmlRoot $_EdgeRouting -xmlElementName "edgeId" -xmlElementText $Edge.Id
        $_EdgeRouting
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeRouting 

# Static Routing

function Get-NsxEdgeStaticRoute {
    
    <#
    .SYNOPSIS
    Retreives Static Routes from the spcified NSX Edge Services Gateway Routing 
    configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeStaticRoute cmdlet retreives the static routes from the 
    routing configuration specified.

    .EXAMPLE
    Get static routes defining on ESG Edge01

    PS C:\> Get-NsxEdge | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Network,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$NextHop       
        
    )
    
    begin {
    }

    process {
    
        #We append the Edge-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        $_EdgeStaticRouting = ($EdgeRouting.staticRouting.CloneNode($True))
        $EdgeStaticRoutes = $_EdgeStaticRouting.SelectSingleNode('descendant::staticRoutes')

        #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called route.
        If ( $EdgeStaticRoutes.SelectSingleNode('descendant::route')) { 

            $RouteCollection = $EdgeStaticRoutes.route
            if ( $PsBoundParameters.ContainsKey('Network')) {
                $RouteCollection = $RouteCollection | ? { $_.network -eq $Network }
            }

            if ( $PsBoundParameters.ContainsKey('NextHop')) {
                $RouteCollection = $RouteCollection | ? { $_.nextHop -eq $NextHop }
            }

            foreach ( $StaticRoute in $RouteCollection ) { 
                Add-XmlElement -xmlRoot $StaticRoute -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
            }

            $RouteCollection
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeStaticRoute

function New-NsxEdgeStaticRoute {
    
    <#
    .SYNOPSIS
    Creates a new static route and adds it to the specified ESGs routing
    configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The New-NsxEdgeStaticRoute cmdlet adds a new static route to the routing
    configuration of the specified Edge Services Gateway.

    .EXAMPLE
    Add a new static route to ESG Edge01 for 1.1.1.0/24 via 10.0.0.200

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | New-NsxEdgeStaticRoute -Network 1.1.1.0/24 -NextHop 10.0.0.200
    
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,200)]
            [int]$Vnic,        
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,9128)]
            [int]$MTU,        
        [Parameter (Mandatory=$False)]
            [string]$Description,       
        [Parameter (Mandatory=$True)]
            [ipAddress]$NextHop,
        [Parameter (Mandatory=$True)]
            [string]$Network,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,255)]
            [int]$AdminDistance        
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        #Create the new route element.
        $Route = $_EdgeRouting.ownerDocument.CreateElement('route')

        #Need to do an xpath query here rather than use PoSH dot notation to get the static route element,
        #as it might be empty, and PoSH silently turns an empty element into a string object, which is rather not what we want... :|
        $StaticRoutes = $_EdgeRouting.staticRouting.SelectSingleNode('descendant::staticRoutes')
        $StaticRoutes.AppendChild($Route) | Out-Null

        Add-XmlElement -xmlRoot $Route -xmlElementName "network" -xmlElementText $Network.ToString()
        Add-XmlElement -xmlRoot $Route -xmlElementName "nextHop" -xmlElementText $NextHop.ToString()

        if ( $PsBoundParameters.ContainsKey("Vnic") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "vnic" -xmlElementText $Vnic.ToString()
        }

        if ( $PsBoundParameters.ContainsKey("MTU") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "mtu" -xmlElementText $MTU.ToString()
        }

        if ( $PsBoundParameters.ContainsKey("Description") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "description" -xmlElementText $Description.ToString()
        }
    
        if ( $PsBoundParameters.ContainsKey("AdminDistance") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "adminDistance" -xmlElementText $AdminDistance.ToString()
        }


        $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
        $body = $_EdgeRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
            $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute -Network $Network -NextHop $NextHop
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeStaticRoute

function Remove-NsxEdgeStaticRoute {
    
    <#
    .SYNOPSIS
    Removes a static route from the specified ESGs routing configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Remove-NsxEdgeStaticRoute cmdlet removes a static route from the routing
    configuration of the specified Edge Services Gateway.

    Routes to be removed can be constructed via a PoSH pipline filter outputing
    route objects as produced by Get-NsxEdgeStaticRoute and passing them on the
    pipeline to Remove-NsxEdgeStaticRoute.

    .EXAMPLE
    Remove a route to 1.1.1.0/24 via 10.0.0.100 from ESG Edge01
    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute | ? { $_.network -eq '1.1.1.0/24' -and $_.nextHop -eq '10.0.0.100' } | Remove-NsxEdgeStaticRoute

    .EXAMPLE
    Remove all routes to 1.1.1.0/24 from ESG Edge01
    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeStaticRoute | ? { $_.network -eq '1.1.1.0/24' } | Remove-NsxEdgeStaticRoute

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeStaticRoute $_ })]
            [System.Xml.XmlElement]$StaticRoute,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our Edge
        $edgeId = $StaticRoute.edgeId
        $routing = Get-NsxEdge -objectId $edgeId | Get-NsxEdgeRouting

        #Remove the edgeId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Need to do an xpath query here to query for a route that matches the one passed in.  
        #Union of nextHop and network should be unique
        $xpathQuery = "//staticRoutes/route[nextHop=`"$($StaticRoute.nextHop)`" and network=`"$($StaticRoute.network)`"]"
        write-debug "XPath query for route nodes to remove is: $xpathQuery"
        $RouteToRemove = $routing.staticRouting.SelectSingleNode($xpathQuery)

        if ( $RouteToRemove ) { 

            write-debug "RouteToRemove Element is: `n $($RouteToRemove.OuterXml | format-xml) "
            $routing.staticRouting.staticRoutes.RemoveChild($RouteToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            }
        }
        else {
            Throw "Route for network $($StaticRoute.network) via $($StaticRoute.nextHop) was not found in routing configuration for Edge $edgeId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdgeStaticRoute

# Prefixes

function Get-NsxEdgePrefix {
    
    <#
    .SYNOPSIS
    Retreives IP Prefixes from the spcified NSX Edge Services Gateway Routing 
    configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgePrefix cmdlet retreives IP prefixes from the 
    routing configuration specified.
    
    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgePrefix

    Retrieve prefixes from Edge Edge01

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgePrefix -Network 1.1.1.0/24

    Retrieve prefix 1.1.1.0/24 from Edge Edge01

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgePrefix -Name CorpNet

    Retrieve prefix CorpNet from Edge Edge01
      
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Network       
        
    )
    
    begin {
    }

    process {
    
        #We append the Edge-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        $_GlobalRoutingConfig = ($EdgeRouting.routingGlobalConfig.CloneNode($True))
        $IpPrefixes = $_GlobalRoutingConfig.SelectSingleNode('child::ipPrefixes')

        #IPPrefixes may not exist...
        if ( $IPPrefixes ) { 
            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called ipPrefix.
            If ( $IpPrefixes.SelectSingleNode('child::ipPrefix')) { 

                $PrefixCollection = $IPPrefixes.ipPrefix
                if ( $PsBoundParameters.ContainsKey('Network')) {
                    $PrefixCollection = $PrefixCollection | ? { $_.ipAddress -eq $Network }
                }

                if ( $PsBoundParameters.ContainsKey('Name')) {
                    $PrefixCollection = $PrefixCollection | ? { $_.name -eq $Name }
                }

                foreach ( $Prefix in $PrefixCollection ) { 
                    Add-XmlElement -xmlRoot $Prefix -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
                }

                $PrefixCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgePrefix

function New-NsxEdgePrefix {
    
    <#
    .SYNOPSIS
    Creates a new IP prefix and adds it to the specified ESGs routing
    configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The New-NsxEdgePrefix cmdlet adds a new IP prefix to the routing
    configuration of the specified Edge Services Gateway.

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | New-NsxEdgePrefix -Name test -Network 1.1.1.0/24

    Create a new prefix called test for network 1.1.1.0/24 on ESG Edge01
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$True)]
            [ValidateNotNullorEmpty()]
            [string]$Name,       
        [Parameter (Mandatory=$True)]
            [ValidateNotNullorEmpty()]
            [string]$Network      
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('child::edgeId')) ) | out-null


        #Need to do an xpath query here rather than use PoSH dot notation to get the IP prefix element,
        #as it might be empty or not exist, and PoSH silently turns an empty element into a string object, which is rather not what we want... :|
        $ipPrefixes = $_EdgeRouting.routingGlobalConfig.SelectSingleNode('child::ipPrefixes')
        if ( -not $ipPrefixes ) { 
            #Create the ipPrefixes element
            $ipPrefixes = $_EdgeRouting.ownerDocument.CreateElement('ipPrefixes')
            $_EdgeRouting.routingGlobalConfig.AppendChild($ipPrefixes) | Out-Null
        }

        #Create the new ipPrefix element.
        $ipPrefix = $_EdgeRouting.ownerDocument.CreateElement('ipPrefix')
        $ipPrefixes.AppendChild($ipPrefix) | Out-Null

        Add-XmlElement -xmlRoot $ipPrefix -xmlElementName "name" -xmlElementText $Name.ToString()
        Add-XmlElement -xmlRoot $ipPrefix -xmlElementName "ipAddress" -xmlElementText $Network.ToString()


        $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
        $body = $_EdgeRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
            $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgePrefix -Network $Network -Name $Name
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgePrefix

function Remove-NsxEdgePrefix {
    
    <#
    .SYNOPSIS
    Removes an IP prefix from the specified ESGs routing configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Remove-NsxEdgePrefix cmdlet removes a IP prefix from the routing
    configuration of the specified Edge Services Gateway.

    Prefixes to be removed can be constructed via a PoSH pipline filter outputing
    prefix objects as produced by Get-NsxEdgePrefix and passing them on the
    pipeline to Remove-NsxEdgePrefix.

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgePrefix -Network 1.1.1.0/24 | Remove-NsxEdgePrefix

    Remove any prefixes for network 1.1.1.0/24 from ESG Edge01


    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgePrefix $_ })]
            [System.Xml.XmlElement]$Prefix,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our Edge
        $edgeId = $Prefix.edgeId
        $routing = Get-NsxEdge -objectId $edgeId | Get-NsxEdgeRouting

        #Remove the edgeId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::edgeId')) ) | out-null

        #Need to do an xpath query here to query for a prefix that matches the one passed in.  
        #Union of nextHop and network should be unique
        $xpathQuery = "/routingGlobalConfig/ipPrefixes/ipPrefix[name=`"$($Prefix.name)`" and ipAddress=`"$($Prefix.ipAddress)`"]"
        write-debug "XPath query for prefix nodes to remove is: $xpathQuery"
        $PrefixToRemove = $routing.SelectSingleNode($xpathQuery)

        if ( $PrefixToRemove ) { 

            write-debug "PrefixToRemove Element is: `n $($PrefixToRemove.OuterXml | format-xml) "
            $routing.routingGlobalConfig.ipPrefixes.RemoveChild($PrefixToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            }
        }
        else {
            Throw "Prefix $($Prefix.Name) for network $($Prefix.network) was not found in routing configuration for Edge $edgeId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdgePrefix

# BGP

function Get-NsxEdgeBgp {
    
    <#
    .SYNOPSIS
    Retreives BGP configuration for the spcified NSX Edge Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeBgp cmdlet retreives the bgp configuration of
    the specified Edge Services Gateway.
    
    .EXAMPLE
    Get the BGP configuration for Edge01

    PS C:\> Get-NsxEdge Edg01 | Get-NsxEdgeRouting | Get-NsxEdgeBgp   
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting
    )
    
    begin {

    }

    process {
    
        #We append the Edge-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        if ( $EdgeRouting.SelectSingleNode('descendant::bgp')) { 
            $bgp = $EdgeRouting.SelectSingleNode('child::bgp').CloneNode($True)
            Add-XmlElement -xmlRoot $bgp -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
            $bgp
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeBgp

function Set-NsxEdgeBgp {
    
    <#
    .SYNOPSIS
    Manipulates BGP specific base configuration of an existing NSX Edge Services 
    Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Set-NsxEdgeBgp cmdlet allows manipulation of the BGP specific configuration
    of a given ESG.
    
   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$EnableBGP,
        [Parameter (Mandatory=$False)]
            [IpAddress]$RouterId,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,65535)]
            [int]$LocalAS,
        [Parameter (Mandatory=$False)]
            [switch]$GracefulRestart,
        [Parameter (Mandatory=$False)]
            [switch]$DefaultOriginate

    )
    
    begin {

    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('EnableBGP') ) { 
            $xmlGlobalConfig = $_EdgeRouting.routingGlobalConfig
            $xmlRouterId = $xmlGlobalConfig.SelectSingleNode('descendant::routerId')
            if ( $EnableBGP ) {
                if ( -not ($xmlRouterId -or $PsBoundParameters.ContainsKey("RouterId"))) {
                    #Existing config missing and no new value set...
                    throw "RouterId must be configured to enable dynamic routing"
                }

                if ($PsBoundParameters.ContainsKey("RouterId")) {
                    #Set Routerid...
                    if ($xmlRouterId) {
                        $xmlRouterId = $RouterId.IPAddresstoString
                    }
                    else{
                        Add-XmlElement -xmlRoot $xmlGlobalConfig -xmlElementName "routerId" -xmlElementText $RouterId.IPAddresstoString
                    }
                }
            }

            $bgp = $_EdgeRouting.SelectSingleNode('descendant::bgp') 

            if ( -not $bgp ) {
                #bgp node does not exist.
                [System.XML.XMLElement]$bgp = $_EdgeRouting.ownerDocument.CreateElement("bgp")
                $_EdgeRouting.appendChild($bgp) | out-null
            }

            if ( $bgp.SelectSingleNode('descendant::enabled')) {
                #Enabled element exists.  Update it.
                $bgp.enabled = $EnableBGP.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $bgp -xmlElementName "enabled" -xmlElementText $EnableBGP.ToString().ToLower()
            }

            if ( $PsBoundParameters.ContainsKey("LocalAS")) { 
                if ( $bgp.SelectSingleNode('descendant::localAS')) {
                    #LocalAS element exists, update it.
                    $bgp.localAS = $LocalAS.ToString()
                }
                else {
                    #LocalAS element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "localAS" -xmlElementText $LocalAS.ToString()
                }
            }
            elseif ( (-not ( $bgp.SelectSingleNode('descendant::localAS')) -and $EnableBGP  )) {
                throw "Existing configuration has no Local AS number specified.  Local AS must be set to enable BGP."
            }

            if ( $PsBoundParameters.ContainsKey("GracefulRestart")) { 
                if ( $bgp.SelectSingleNode('descendant::gracefulRestart')) {
                    #element exists, update it.
                    $bgp.gracefulRestart = $GracefulRestart.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "gracefulRestart" -xmlElementText $GracefulRestart.ToString().ToLower()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultOriginate")) { 
                if ( $bgp.SelectSingleNode('descendant::defaultOriginate')) {
                    #element exists, update it.
                    $bgp.defaultOriginate = $DefaultOriginate.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "defaultOriginate" -xmlElementText $DefaultOriginate.ToString().ToLower()
                }
            }
        }

        $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
        $body = $_EdgeRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
            $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeBgp
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxEdgeBgp

function Get-NsxEdgeBgpNeighbour {
    
    <#
    .SYNOPSIS
    Returns BGP neighbours from the spcified NSX Edge Services Gateway BGP 
    configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeBgpNeighbour cmdlet retreives the BGP neighbours from the 
    BGP configuration specified.

    .EXAMPLE
    Get all BGP neighbours defined on Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeBgpNeighbour
    
    .EXAMPLE
    Get BGP neighbour 1.1.1.1 defined on Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeBgpNeighbour -IpAddress 1.1.1.1

    .EXAMPLE
    Get all BGP neighbours with Remote AS 1234 defined on Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeBgpNeighbour | ? { $_.RemoteAS -eq '1234' }

    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Network,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$IpAddress,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,65535)]
            [int]$RemoteAS              
    )
    
    begin {
    }

    process {
    
        $bgp = $EdgeRouting.SelectSingleNode('descendant::bgp')

        if ( $bgp ) {

            $_bgp = $bgp.CloneNode($True)
            $BgpNeighbours = $_bgp.SelectSingleNode('descendant::bgpNeighbours')


            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called bgpNeighbour.
            if ( $BgpNeighbours.SelectSingleNode('descendant::bgpNeighbour')) { 

                $NeighbourCollection = $BgpNeighbours.bgpNeighbour
                if ( $PsBoundParameters.ContainsKey('IpAddress')) {
                    $NeighbourCollection = $NeighbourCollection | ? { $_.ipAddress -eq $IpAddress }
                }

                if ( $PsBoundParameters.ContainsKey('RemoteAS')) {
                    $NeighbourCollection = $NeighbourCollection | ? { $_.remoteAS -eq $RemoteAS }
                }

                foreach ( $Neighbour in $NeighbourCollection ) { 
                    #We append the Edge-id to the associated neighbour config XML to enable pipeline workflows and 
                    #consistent readable output
                    Add-XmlElement -xmlRoot $Neighbour -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
                }

                $NeighbourCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeBgpNeighbour

function New-NsxEdgeBgpNeighbour {
    
    <#
    .SYNOPSIS
    Creates a new BGP neighbour and adds it to the specified ESGs BGP
    configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The New-NsxEdgeBgpNeighbour cmdlet adds a new BGP neighbour to the bgp
    configuration of the specified Edge Services Gateway.

    .EXAMPLE
    Add a new neighbour 1.2.3.4 with remote AS number 1234 with defaults.

    PS C:\> Get-NsxEdge | Get-NsxEdgeRouting | New-NsxEdgeBgpNeighbour -IpAddress 1.2.3.4 -RemoteAS 1234

    .EXAMPLE
    Add a new neighbour 1.2.3.4 with remote AS number 22235 specifying weight, holddown and keepalive timers and dont prompt for confirmation.

    PowerCLI C:\> Get-NsxEdge | Get-NsxEdgeRouting | New-NsxEdgeBgpNeighbour -IpAddress 1.2.3.4 -RemoteAS 22235 -Confirm:$false -Weight 90 -HoldDownTimer 240 -KeepAliveTimer 90 -confirm:$false

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$IpAddress,
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,65535)]
            [int]$RemoteAS,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,65535)]
            [int]$Weight,
        [Parameter (Mandatory=$false)]
            [ValidateRange(2,65535)]
            [int]$HoldDownTimer,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65534)]
            [int]$KeepAliveTimer,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [string]$Password     
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Create the new bgpNeighbour element.
        $Neighbour = $_EdgeRouting.ownerDocument.CreateElement('bgpNeighbour')

        #Need to do an xpath query here rather than use PoSH dot notation to get the bgp element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $bgp = $_EdgeRouting.SelectSingleNode('descendant::bgp')
        if ( $bgp ) { 
            $bgp.selectSingleNode('descendant::bgpNeighbours').AppendChild($Neighbour) | Out-Null

            Add-XmlElement -xmlRoot $Neighbour -xmlElementName "ipAddress" -xmlElementText $IpAddress.ToString()
            Add-XmlElement -xmlRoot $Neighbour -xmlElementName "remoteAS" -xmlElementText $RemoteAS.ToString()

            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey("Weight") ) { 
                Add-XmlElement -xmlRoot $Neighbour -xmlElementName "weight" -xmlElementText $Weight.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("HoldDownTimer") ) { 
                Add-XmlElement -xmlRoot $Neighbour -xmlElementName "holdDownTimer" -xmlElementText $HoldDownTimer.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("KeepAliveTimer") ) { 
                Add-XmlElement -xmlRoot $Neighbour -xmlElementName "keepAliveTimer" -xmlElementText $KeepAliveTimer.ToString()
            }


            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $_EdgeRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
                Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeBgpNeighbour -IpAddress $IpAddress -RemoteAS $RemoteAS
            }
        }
        else {
            throw "BGP is not enabled on edge $edgeID.  Enable BGP using Set-NsxEdgeRouting or Set-NsxEdgeBGP first."
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeBgpNeighbour

function Remove-NsxEdgeBgpNeighbour {
    
    <#
    .SYNOPSIS
    Removes a BGP neigbour from the specified ESGs BGP configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Remove-NsxEdgeBgpNeighbour cmdlet removes a BGP neighbour route from the 
    bgp configuration of the specified Edge Services Gateway.

    Neighbours to be removed can be constructed via a PoSH pipline filter outputing
    neighbour objects as produced by Get-NsxEdgeBgpNeighbour and passing them on the
    pipeline to Remove-NsxEdgeBgpNeighbour.

    .EXAMPLE
    Remove the BGP neighbour 1.1.1.2 from the the edge Edge01's bgp configuration

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeBgpNeighbour | ? { $_.ipaddress -eq '1.1.1.2' } |  Remove-NsxEdgeBgpNeighbour 
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeBgpNeighbour $_ })]
            [System.Xml.XmlElement]$BgpNeighbour,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our Edge
        $edgeId = $BgpNeighbour.edgeId
        $routing = Get-NsxEdge -objectId $edgeId | Get-NsxEdgeRouting

        #Remove the edgeId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Validate the BGP node exists on the edge 
        if ( -not $routing.SelectSingleNode('descendant::bgp')) { throw "BGP is not enabled on ESG $edgeId.  Enable BGP and try again." }

        #Need to do an xpath query here to query for a bgp neighbour that matches the one passed in.  
        #Union of ipaddress and remote AS should be unique (though this is not enforced by the API, 
        #I cant see why having duplicate neighbours with same ip and AS would be useful...maybe 
        #different filters?)
        #Will probably need to include additional xpath query filters here in the query to include 
        #matching on filters to better handle uniquness amongst bgp neighbours with same ip and remoteAS

        $xpathQuery = "//bgpNeighbours/bgpNeighbour[ipAddress=`"$($BgpNeighbour.ipAddress)`" and remoteAS=`"$($BgpNeighbour.remoteAS)`"]"
        write-debug "XPath query for neighbour nodes to remove is: $xpathQuery"
        $NeighbourToRemove = $routing.bgp.SelectSingleNode($xpathQuery)

        if ( $NeighbourToRemove ) { 

            write-debug "NeighbourToRemove Element is: `n $($NeighbourToRemove.OuterXml | format-xml) "
            $routing.bgp.bgpNeighbours.RemoveChild($NeighbourToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            }
        }
        else {
            Throw "Neighbour $($BgpNeighbour.ipAddress) with Remote AS $($BgpNeighbour.RemoteAS) was not found in routing configuration for Edge $edgeId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdgeBgpNeighbour

# OSPF

function Get-NsxEdgeOspf {
    
    <#
    .SYNOPSIS
    Retreives OSPF configuration for the spcified NSX Edge Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeOspf cmdlet retreives the OSPF configuration of
    the specified Edge Services Gateway.
    
    .EXAMPLE
    Get the OSPF configuration for Edge01

    PS C:\> Get-NsxEdge Edg01 | Get-NsxEdgeRouting | Get-NsxEdgeOspf
    
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting
    )
    
    begin {

    }

    process {
    
        #We append the Edge-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        if ( $EdgeRouting.SelectSingleNode('descendant::ospf')) { 
            $ospf = $EdgeRouting.ospf.CloneNode($True)
            Add-XmlElement -xmlRoot $ospf -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
            $ospf
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeOspf

function Set-NsxEdgeOspf {
    
    <#
    .SYNOPSIS
    Manipulates OSPF specific base configuration of an existing NSX Edge 
    Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Set-NsxEdgeOspf cmdlet allows manipulation of the OSPF specific 
    configuration of a given ESG.
    
   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$EnableOSPF,
        [Parameter (Mandatory=$False)]
            [IpAddress]$RouterId,
        [Parameter (Mandatory=$False)]
            [switch]$GracefulRestart,
        [Parameter (Mandatory=$False)]
            [switch]$DefaultOriginate

    )
    
    begin {

    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('EnableOSPF') ) { 
            $xmlGlobalConfig = $_EdgeRouting.routingGlobalConfig
            $xmlRouterId = $xmlGlobalConfig.SelectSingleNode('descendant::routerId')
            if ( $EnableOSPF ) {
                if ( -not ($xmlRouterId -or $PsBoundParameters.ContainsKey("RouterId"))) {
                    #Existing config missing and no new value set...
                    throw "RouterId must be configured to enable dynamic routing"
                }

                if ($PsBoundParameters.ContainsKey("RouterId")) {
                    #Set Routerid...
                    if ($xmlRouterId) {
                        $xmlRouterId = $RouterId.IPAddresstoString
                    }
                    else{
                        Add-XmlElement -xmlRoot $xmlGlobalConfig -xmlElementName "routerId" -xmlElementText $RouterId.IPAddresstoString
                    }
                }
            }

            $ospf = $_EdgeRouting.SelectSingleNode('descendant::ospf') 

            if ( -not $ospf ) {
                #ospf node does not exist.
                [System.XML.XMLElement]$ospf = $_EdgeRouting.ownerDocument.CreateElement("ospf")
                $_EdgeRouting.appendChild($ospf) | out-null
            }

            if ( $ospf.SelectSingleNode('descendant::enabled')) {
                #Enabled element exists.  Update it.
                $ospf.enabled = $EnableOSPF.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $ospf -xmlElementName "enabled" -xmlElementText $EnableOSPF.ToString().ToLower()
            }

            if ( $PsBoundParameters.ContainsKey("GracefulRestart")) { 
                if ( $ospf.SelectSingleNode('descendant::gracefulRestart')) {
                    #element exists, update it.
                    $ospf.gracefulRestart = $GracefulRestart.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "gracefulRestart" -xmlElementText $GracefulRestart.ToString().ToLower()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultOriginate")) { 
                if ( $ospf.SelectSingleNode('descendant::defaultOriginate')) {
                    #element exists, update it.
                    $ospf.defaultOriginate = $DefaultOriginate.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "defaultOriginate" -xmlElementText $DefaultOriginate.ToString().ToLower()
                }
            }
        }

        $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
        $body = $_EdgeRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
            $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeBgp
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxEdgeOspf

function Get-NsxEdgeOspfArea {
    
    <#
    .SYNOPSIS
    Returns OSPF Areas defined in the spcified NSX Edge Services Gateway OSPF 
    configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeOspfArea cmdlet retreives the OSPF Areas from the OSPF 
    configuration specified.

    .EXAMPLE
    Get all areas defined on Edge01.

    PS C:\> C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeOspfArea 
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,4294967295)]
            [int]$AreaId              
    )
    
    begin {
    }

    process {
    
        $ospf = $EdgeRouting.SelectSingleNode('descendant::ospf')

        if ( $ospf ) {

            $_ospf = $ospf.CloneNode($True)
            $OspfAreas = $_ospf.SelectSingleNode('descendant::ospfAreas')


            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called ospfArea.
            if ( $OspfAreas.SelectSingleNode('descendant::ospfArea')) { 

                $AreaCollection = $OspfAreas.ospfArea
                if ( $PsBoundParameters.ContainsKey('AreaId')) {
                    $AreaCollection = $AreaCollection | ? { $_.areaId -eq $AreaId }
                }

                foreach ( $Area in $AreaCollection ) { 
                    #We append the Edge-id to the associated Area config XML to enable pipeline workflows and 
                    #consistent readable output
                    Add-XmlElement -xmlRoot $Area -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
                }

                $AreaCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeOspfArea

function Remove-NsxEdgeOspfArea {
    
    <#
    .SYNOPSIS
    Removes an OSPF area from the specified ESGs OSPF configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Remove-NsxEdgeOspfArea cmdlet removes a BGP neighbour route from the 
    bgp configuration of the specified Edge Services Gateway.

    Areas to be removed can be constructed via a PoSH pipline filter outputing
    area objects as produced by Get-NsxEdgeOspfArea and passing them on the
    pipeline to Remove-NsxEdgeOspfArea.
    
    .EXAMPLE
    Remove area 51 from ospf configuration on Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeOspfArea -AreaId 51 | Remove-NsxEdgeOspfArea
    
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeOspfArea $_ })]
            [System.Xml.XmlElement]$OspfArea,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our Edge
        $edgeId = $OspfArea.edgeId
        $routing = Get-NsxEdge -objectId $edgeId | Get-NsxEdgeRouting

        #Remove the edgeId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Validate the OSPF node exists on the edge 
        if ( -not $routing.SelectSingleNode('descendant::ospf')) { throw "OSPF is not enabled on ESG $edgeId.  Enable OSPF and try again." }
        if ( -not ($routing.ospf.enabled -eq 'true') ) { throw "OSPF is not enabled on ESG $edgeId.  Enable OSPF and try again." }

        

        $xpathQuery = "//ospfAreas/ospfArea[areaId=`"$($OspfArea.areaId)`"]"
        write-debug "XPath query for area nodes to remove is: $xpathQuery"
        $AreaToRemove = $routing.ospf.SelectSingleNode($xpathQuery)

        if ( $AreaToRemove ) { 

            write-debug "AreaToRemove Element is: `n $($AreaToRemove.OuterXml | format-xml) "
            $routing.ospf.ospfAreas.RemoveChild($AreaToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            }
        }
        else {
            Throw "Area $($OspfArea.areaId) was not found in routing configuration for Edge $edgeId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdgeOspfArea

function New-NsxEdgeOspfArea {
    
    <#
    .SYNOPSIS
    Creates a new OSPF Area and adds it to the specified ESGs OSPF 
    configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The New-NsxEdgeOspfArea cmdlet adds a new OSPF Area to the ospf
    configuration of the specified Edge Services Gateway.

    .EXAMPLE
    Create area 50 as a normal type on ESG Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | New-NsxEdgeOspfArea -AreaId 50

    .EXAMPLE
    Create area 10 as a nssa type on ESG Edge01 with password authentication

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | New-NsxEdgeOspfArea -AreaId 10 -Type password -Password "Secret"


   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,4294967295)]
            [uint32]$AreaId,
        [Parameter (Mandatory=$false)]
            [ValidateSet("normal","nssa",IgnoreCase = $false)]
            [string]$Type,
        [Parameter (Mandatory=$false)]
            [ValidateSet("none","password","md5",IgnoreCase = $false)]
            [string]$AuthenticationType="none",
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [string]$Password
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Create the new ospfArea element.
        $Area = $_EdgeRouting.ownerDocument.CreateElement('ospfArea')

        #Need to do an xpath query here rather than use PoSH dot notation to get the ospf element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $ospf = $_EdgeRouting.SelectSingleNode('descendant::ospf')
        if ( $ospf ) { 
            $ospf.selectSingleNode('descendant::ospfAreas').AppendChild($Area) | Out-Null

            Add-XmlElement -xmlRoot $Area -xmlElementName "areaId" -xmlElementText $AreaId.ToString()

            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey("Type") ) { 
                Add-XmlElement -xmlRoot $Area -xmlElementName "type" -xmlElementText $Type.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("AuthenticationType") -or $PsBoundParameters.ContainsKey("Password") ) { 
                switch ($AuthenticationType) {

                    "none" { 
                        if ( $PsBoundParameters.ContainsKey('Password') ) { 
                            throw "Authentication type must be other than none to specify a password."
                        }
                        #Default value - do nothing
                    }

                    default { 
                        if ( -not ( $PsBoundParameters.ContainsKey('Password')) ) {
                            throw "Must specify a password if Authentication type is not none."
                        }
                        $Authentication = $Area.ownerDocument.CreateElement("authentication")
                        $Area.AppendChild( $Authentication ) | out-null

                        Add-XmlElement -xmlRoot $Authentication -xmlElementName "type" -xmlElementText $AuthenticationType
                        Add-XmlElement -xmlRoot $Authentication -xmlElementName "value" -xmlElementText $Password
                    }
                }
            }

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $_EdgeRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
                Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeOspfArea -AreaId $AreaId
            }
        }
        else {
            throw "OSPF is not enabled on edge $edgeID.  Enable OSPF using Set-NsxEdgeRouting or Set-NsxEdgeOSPF first."
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeOspfArea

function Get-NsxEdgeOspfInterface {
    
    <#
    .SYNOPSIS
    Returns OSPF Interface mappings defined in the spcified NSX Edge Services 
    Gateway OSPF configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeOspfInterface cmdlet retreives the OSPF Area to interfaces 
    mappings from the OSPF configuration specified.

    .EXAMPLE
    Get all OSPF Area to Interface mappings on ESG Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeOspfInterface
   
    .EXAMPLE
    Get OSPF Area to Interface mapping for Area 10 on ESG Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeOspfInterface -AreaId 10
   
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,4294967295)]
            [int]$AreaId,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,200)]
            [int]$vNicId    
    )
    
    begin {
    }

    process {
    
        $ospf = $EdgeRouting.SelectSingleNode('descendant::ospf')

        if ( $ospf ) {

            $_ospf = $ospf.CloneNode($True)
            $OspfInterfaces = $_ospf.SelectSingleNode('descendant::ospfInterfaces')


            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called ospfArea.
            if ( $OspfInterfaces.SelectSingleNode('descendant::ospfInterface')) { 

                $InterfaceCollection = $OspfInterfaces.ospfInterface
                if ( $PsBoundParameters.ContainsKey('AreaId')) {
                    $InterfaceCollection = $InterfaceCollection | ? { $_.areaId -eq $AreaId }
                }

                if ( $PsBoundParameters.ContainsKey('vNicId')) {
                    $InterfaceCollection = $InterfaceCollection | ? { $_.vnic -eq $vNicId }
                }

                foreach ( $Interface in $InterfaceCollection ) { 
                    #We append the Edge-id to the associated Area config XML to enable pipeline workflows and 
                    #consistent readable output
                    Add-XmlElement -xmlRoot $Interface -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId
                }

                $InterfaceCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeOspfInterface

function Remove-NsxEdgeOspfInterface {
    
    <#
    .SYNOPSIS
    Removes an OSPF Interface from the specified ESGs OSPF configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Remove-NsxEdgeOspfInterface cmdlet removes a BGP neighbour route from 
    the bgp configuration of the specified Edge Services Gateway.

    Interfaces to be removed can be constructed via a PoSH pipline filter 
    outputing interface objects as produced by Get-NsxEdgeOspfInterface and 
    passing them on the pipeline to Remove-NsxEdgeOspfInterface.
    
    .EXAMPLE
    Remove Interface to Area mapping for area 51 from ESG Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeOspfInterface -AreaId 51 | Remove-NsxEdgeOspfInterface

    .EXAMPLE
    Remove all Interface to Area mappings from ESG Edge01 without confirmation.

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeOspfInterface | Remove-NsxEdgeOspfInterface -confirm:$false

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeOspfInterface $_ })]
            [System.Xml.XmlElement]$OspfInterface,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our Edge
        $edgeId = $OspfInterface.edgeId
        $routing = Get-NsxEdge -objectId $edgeId | Get-NsxEdgeRouting

        #Remove the edgeId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Validate the OSPF node exists on the edge 
        if ( -not $routing.SelectSingleNode('descendant::ospf')) { throw "OSPF is not enabled on ESG $edgeId.  Enable OSPF and try again." }
        if ( -not ($routing.ospf.enabled -eq 'true') ) { throw "OSPF is not enabled on ESG $edgeId.  Enable OSPF and try again." }

        

        $xpathQuery = "//ospfInterfaces/ospfInterface[areaId=`"$($OspfInterface.areaId)`"]"
        write-debug "XPath query for interface nodes to remove is: $xpathQuery"
        $InterfaceToRemove = $routing.ospf.SelectSingleNode($xpathQuery)

        if ( $InterfaceToRemove ) { 

            write-debug "InterfaceToRemove Element is: `n $($InterfaceToRemove.OuterXml | format-xml) "
            $routing.ospf.ospfInterfaces.RemoveChild($InterfaceToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            }
        }
        else {
            Throw "Interface $($OspfInterface.areaId) was not found in routing configuration for Edge $edgeId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdgeOspfInterface

function New-NsxEdgeOspfInterface {
    
    <#
    .SYNOPSIS
    Creates a new OSPF Interface to Area mapping and adds it to the specified 
    ESGs OSPF configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The New-NsxEdgeOspfInterface cmdlet adds a new OSPF Area to Interface 
    mapping to the ospf configuration of the specified Edge Services Gateway.

    .EXAMPLE
    Add a mapping for Area 10 to Interface 0 on ESG Edge01

    PS C:\> Get-NsxEdge Edge01 | Get-NsxEdgeRouting | New-NsxEdgeOspfInterface -AreaId 10 -Vnic 0
   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,4294967295)]
            [uint32]$AreaId,
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,200)]
            [int]$Vnic,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,255)]
            [int]$HelloInterval,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65535)]
            [int]$DeadInterval,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,255)]
            [int]$Priority,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65535)]
            [int]$Cost,
        [Parameter (Mandatory=$false)]
            [switch]$IgnoreMTU

    )

    
    begin {
    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Create the new ospfInterface element.
        $Interface = $_EdgeRouting.ownerDocument.CreateElement('ospfInterface')

        #Need to do an xpath query here rather than use PoSH dot notation to get the ospf element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $ospf = $_EdgeRouting.SelectSingleNode('descendant::ospf')
        if ( $ospf ) { 
            $ospf.selectSingleNode('descendant::ospfInterfaces').AppendChild($Interface) | Out-Null

            Add-XmlElement -xmlRoot $Interface -xmlElementName "areaId" -xmlElementText $AreaId.ToString()
            Add-XmlElement -xmlRoot $Interface -xmlElementName "vnic" -xmlElementText $Vnic.ToString()

            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey("HelloInterval") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "helloInterval" -xmlElementText $HelloInterval.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("DeadInterval") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "deadInterval" -xmlElementText $DeadInterval.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("Priority") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "priority" -xmlElementText $Priority.ToString()
            }
            
            if ( $PsBoundParameters.ContainsKey("Cost") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "cost" -xmlElementText $Cost.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("IgnoreMTU") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "mtuIgnore" -xmlElementText $IgnoreMTU.ToString().ToLower()
            }

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $_EdgeRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
                Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeOspfInterface -AreaId $AreaId
            }
        }
        else {
            throw "OSPF is not enabled on edge $edgeID.  Enable OSPF using Set-NsxEdgeRouting or Set-NsxEdgeOSPF first."
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeOspfInterface

# Redistribution Rules

function Get-NsxEdgeRedistributionRule {
    
    <#
    .SYNOPSIS
    Returns dynamic route redistribution rules defined in the spcified NSX Edge
    Services Gateway routing configuration.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Get-NsxEdgeRedistributionRule cmdlet retreives the route redistribution
    rules defined in the ospf and bgp configurations for the specified ESG.

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeRedistributionRule -Learner ospf

    Get all Redistribution rules for ospf on ESG Edge01
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,
        [Parameter (Mandatory=$false)]
            [ValidateSet("ospf","bgp")]
            [string]$Learner,
        [Parameter (Mandatory=$false)]
            [int]$Id
    )
    
    begin {
    }

    process {
    
        #Rules can be defined in either ospf or bgp (isis as well, but who cares huh? :) )
        if ( ( -not $PsBoundParameters.ContainsKey('Learner')) -or ($PsBoundParameters.ContainsKey('Learner') -and $Learner -eq 'ospf')) {

            $ospf = $EdgeRouting.SelectSingleNode('child::ospf')

            if ( $ospf ) {

                $_ospf = $ospf.CloneNode($True)
                if ( $_ospf.SelectSingleNode('child::redistribution/rules/rule') ) { 

                    $OspfRuleCollection = $_ospf.redistribution.rules.rule

                    foreach ( $rule in $OspfRuleCollection ) { 
                        #We append the Edge-id to the associated rule config XML to enable pipeline workflows and 
                        #consistent readable output
                        Add-XmlElement -xmlRoot $rule -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId

                        #Add the learner to be consistent with the view the UI gives
                        Add-XmlElement -xmlRoot $rule -xmlElementName "learner" -xmlElementText "ospf"

                    }

                    if ( $PsBoundParameters.ContainsKey('Id')) {
                        $OspfRuleCollection = $OspfRuleCollection | ? { $_.id -eq $Id }
                    }

                    $OspfRuleCollection
                }
            }
        }

        if ( ( -not $PsBoundParameters.ContainsKey('Learner')) -or ($PsBoundParameters.ContainsKey('Learner') -and $Learner -eq 'bgp')) {

            $bgp = $EdgeRouting.SelectSingleNode('child::bgp')
            if ( $bgp ) {

                $_bgp = $bgp.CloneNode($True)
                if ( $_bgp.SelectSingleNode('child::redistribution/rules') ) { 

                    $BgpRuleCollection = $_bgp.redistribution.rules.rule

                    foreach ( $rule in $BgpRuleCollection ) { 
                        #We append the Edge-id to the associated rule config XML to enable pipeline workflows and 
                        #consistent readable output
                        Add-XmlElement -xmlRoot $rule -xmlElementName "edgeId" -xmlElementText $EdgeRouting.EdgeId

                        #Add the learner to be consistent with the view the UI gives
                        Add-XmlElement -xmlRoot $rule -xmlElementName "learner" -xmlElementText "bgp"
                    }

                    if ( $PsBoundParameters.ContainsKey('Id')) {
                        $BgpRuleCollection = $BgpRuleCollection | ? { $_.id -eq $Id }
                    }
                    $BgpRuleCollection
                }
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxEdgeRedistributionRule

function Remove-NsxEdgeRedistributionRule {
    
    <#
    .SYNOPSIS
    Removes a route redistribution rule from the specified ESGs  configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The Remove-NsxEdgeRedistributionRule cmdlet removes a route redistribution
    rule from the configuration of the specified Edge Services Gateway.

    Interfaces to be removed can be constructed via a PoSH pipline filter 
    outputing interface objects as produced by Get-NsxEdgeRedistributionRule and 
    passing them on the pipeline to Remove-NsxEdgeRedistributionRule.
  
    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | Get-NsxEdgeRedistributionRule -Learner ospf | Remove-NsxEdgeRedistributionRule

    Remove all ospf redistribution rules from Edge01
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRedistributionRule $_ })]
            [System.Xml.XmlElement]$RedistributionRule,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our Edge
        $edgeId = $RedistributionRule.edgeId
        $routing = Get-NsxEdge -objectId $edgeId | Get-NsxEdgeRouting

        #Remove the edgeId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::edgeId')) ) | out-null

        #Validate the learner protocol node exists on the edge 
        if ( -not $routing.SelectSingleNode("child::$($RedistributionRule.learner)")) {
            throw "Rule learner protocol $($RedistributionRule.learner) is not enabled on ESG $edgeId.  Use Get-NsxEdge <this edge> | Get-NsxEdgerouting | Get-NsxEdgeRedistributionRule to get the rule you want to remove." 
        }

        #Make XPath do all the hard work... Wish I was able to just compare the from node, but id doesnt appear possible with xpath 1.0
        $xpathQuery = "child::$($RedistributionRule.learner)/redistribution/rules/rule[action=`"$($RedistributionRule.action)`""
        $xPathQuery += " and from/connected=`"$($RedistributionRule.from.connected)`" and from/static=`"$($RedistributionRule.from.static)`""
        $xPathQuery += " and from/ospf=`"$($RedistributionRule.from.ospf)`" and from/bgp=`"$($RedistributionRule.from.bgp)`""
        $xPathQuery += " and from/isis=`"$($RedistributionRule.from.isis)`""

        if ( $RedistributionRule.SelectSingleNode('child::prefixName')) { 

            $xPathQuery += " and prefixName=`"$($RedistributionRule.prefixName)`""
        }
        
        $xPathQuery += "]"

        write-debug "XPath query for rule node to remove is: $xpathQuery"
        
        $RuleToRemove = $routing.SelectSingleNode($xpathQuery)

        if ( $RuleToRemove ) { 

            write-debug "RuleToRemove Element is: `n $($RuleToRemove | format-xml) "
            $routing.$($RedistributionRule.Learner).redistribution.rules.RemoveChild($RuleToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
            }
        }
        else {
            Throw "Rule Id $($RedistributionRule.Id) was not found in the $($RedistributionRule.Learner) routing configuration for Edge $edgeId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxEdgeRedistributionRule

function New-NsxEdgeRedistributionRule {
    
    <#
    .SYNOPSIS
    Creates a new route redistribution rule and adds it to the specified ESGs 
    configuration. 

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. Each NSX Edge virtual
    appliance can have a total of ten uplink and internal network interfaces and
    up to 200 subinterfaces.  Multiple external IP addresses can be configured 
    for load balancer, site‐to‐site VPN, and NAT services.

    ESGs perform ipv4 and ipv6 routing functions for connected networks and 
    support both static and dynamic routing via OSPF, ISIS and BGP.

    The New-NsxEdgeRedistributionRule cmdlet adds a new route redistribution 
    rule to the configuration of the specified Edge Services Gateway.

    .EXAMPLE
    Get-NsxEdge Edge01 | Get-NsxEdgeRouting | New-NsxEdgeRedistributionRule -PrefixName test -Learner ospf -FromConnected -FromStatic -Action permit

    Create a new permit Redistribution Rule for prefix test (note, prefix must already exist, and is case sensistive) for ospf.
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-EdgeRouting $_ })]
            [System.Xml.XmlElement]$EdgeRouting,    
        [Parameter (Mandatory=$True)]
            [ValidateSet("ospf","bgp",IgnoreCase=$false)]
            [String]$Learner,
        [Parameter (Mandatory=$false)]
            [String]$PrefixName,    
        [Parameter (Mandatory=$false)]
            [switch]$FromConnected,
        [Parameter (Mandatory=$false)]
            [switch]$FromStatic,
        [Parameter (Mandatory=$false)]
            [switch]$FromOspf,
        [Parameter (Mandatory=$false)]
            [switch]$FromBgp,
        [Parameter (Mandatory=$False)]
            [ValidateSet("permit","deny",IgnoreCase=$false)]
            [String]$Action="permit",  
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true  

    )

    
    begin {
    }

    process {

        #Create private xml element
        $_EdgeRouting = $EdgeRouting.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_EdgeRouting.edgeId
        $_EdgeRouting.RemoveChild( $($_EdgeRouting.SelectSingleNode('child::edgeId')) ) | out-null

        #Need to do an xpath query here rather than use PoSH dot notation to get the protocol element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $ProtocolElement = $_EdgeRouting.SelectSingleNode("child::$Learner")

        if ( (-not $ProtocolElement) -or ($ProtocolElement.Enabled -ne 'true')) { 

            throw "The $Learner protocol is not enabled on Edge $edgeId.  Enable it and try again."
        }
        else {
        
            #Create the new rule element. 
            $Rule = $_EdgeRouting.ownerDocument.CreateElement('rule')
            $ProtocolElement.selectSingleNode('child::redistribution/rules').AppendChild($Rule) | Out-Null

            Add-XmlElement -xmlRoot $Rule -xmlElementName "action" -xmlElementText $Action
            if ( $PsBoundParameters.ContainsKey("PrefixName") ) { 
                Add-XmlElement -xmlRoot $Rule -xmlElementName "prefixName" -xmlElementText $PrefixName.ToString()
            }


            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey('FromConnected') -or $PsBoundParameters.ContainsKey('FromStatic') -or
                 $PsBoundParameters.ContainsKey('FromOspf') -or $PsBoundParameters.ContainsKey('FromBgp') ) {

                $FromElement = $Rule.ownerDocument.CreateElement('from')
                $Rule.AppendChild($FromElement) | Out-Null

                if ( $PsBoundParameters.ContainsKey("FromConnected") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "connected" -xmlElementText $FromConnected.ToString().ToLower()
                }

                if ( $PsBoundParameters.ContainsKey("FromStatic") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "static" -xmlElementText $FromStatic.ToString().ToLower()
                }
    
                if ( $PsBoundParameters.ContainsKey("FromOspf") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "ospf" -xmlElementText $FromOspf.ToString().ToLower()
                }

                if ( $PsBoundParameters.ContainsKey("FromBgp") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "bgp" -xmlElementText $FromBgp.ToString().ToLower()
                }
            }

            $URI = "/api/4.0/edges/$($EdgeId)/routing/config"
            $body = $_EdgeRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "Edge Services Gateway routing update will modify existing Edge configuration."
                $question = "Proceed with Update of Edge Services Gateway $($EdgeId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update Edge Services Gateway $($EdgeId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed
                (Get-NsxEdge -objectId $EdgeId | Get-NsxEdgeRouting | Get-NsxEdgeRedistributionRule -Learner $Learner)[-1]
                
            }
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxEdgeRedistributionRule

#########
#########
# DLR Routing related functions

function Set-NsxLogicalRouterRouting {
    
    <#
    .SYNOPSIS
    Configures global routing configuration of an existing NSX Logical Router

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Set-NsxLogicalRouterRouting cmdlet configures the global routing 
    configuration of the specified LogicalRouter.
    
    .EXAMPLE
    Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -DefaultGatewayVnic 0 -DefaultGatewayAddress 10.0.0.101
    
    Configure the default route of the LogicalRouter.
    
    .EXAMPLE
    Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -EnableECMP
    
    Enable ECMP

    .EXAMPLE
    Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -EnableOSPF -RouterId 1.1.1.1 -ForwardingAddress 1.1.1.1 -ProtocolAddress 1.1.1.2

    Enable OSPF

    .EXAMPLE
    Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -EnableBGP -RouterId 1.1.1.1 -LocalAS 1234

    Enable BGP

    .EXAMPLE
    Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Set-NsxLogicalRouterRouting -EnableOspfRouteRedistribution:$false -Confirm:$false

    Disable OSPF Route Redistribution without confirmation.
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$EnableOspf,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$ProtocolAddress,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$ForwardingAddress,
        [Parameter (Mandatory=$False)]
            [switch]$EnableBgp,
        [Parameter (Mandatory=$False)]
            [IpAddress]$RouterId,
        [Parameter (MAndatory=$False)]
            [ValidateRange(0,65535)]
            [int]$LocalAS,
        [Parameter (Mandatory=$False)]
            [switch]$EnableEcmp,
        [Parameter (Mandatory=$False)]
            [switch]$EnableOspfRouteRedistribution,
        [Parameter (Mandatory=$False)]
            [switch]$EnableBgpRouteRedistribution,
        [Parameter (Mandatory=$False)]
            [switch]$EnableLogging,
        [Parameter (Mandatory=$False)]
            [ValidateSet("emergency","alert","critical","error","warning","notice","info","debug")]
            [string]$LogLevel,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,200)]
            [int]$DefaultGatewayVnic,        
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,9128)]
            [int]$DefaultGatewayMTU,        
        [Parameter (Mandatory=$False)]
            [string]$DefaultGatewayDescription,       
        [Parameter (Mandatory=$False)]
            [ipAddress]$DefaultGatewayAddress,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,255)]
            [int]$DefaultGatewayAdminDistance        

    )
    
    begin {

    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('EnableOSPF') -or $PsBoundParameters.ContainsKey('EnableBGP') ) { 
            $xmlGlobalConfig = $_LogicalRouterRouting.routingGlobalConfig
            $xmlRouterId = $xmlGlobalConfig.SelectSingleNode('child::routerId')
            if ( $EnableOSPF -or $EnableBGP ) {
                if ( -not ($xmlRouterId -or $PsBoundParameters.ContainsKey("RouterId"))) {
                    #Existing config missing and no new value set...
                    throw "RouterId must be configured to enable dynamic routing"
                }

                if ($PsBoundParameters.ContainsKey("RouterId")) {
                    #Set Routerid...
                    if ($xmlRouterId) {
                        $xmlRouterId = $RouterId.IPAddresstoString
                    }
                    else{
                        Add-XmlElement -xmlRoot $xmlGlobalConfig -xmlElementName "routerId" -xmlElementText $RouterId.IPAddresstoString
                    }
                }
            }
        }

        if ( $PsBoundParameters.ContainsKey('EnableOSPF')) { 
            $ospf = $_LogicalRouterRouting.SelectSingleNode('child::ospf') 
            if ( -not $ospf ) {
                #ospf node does not exist.
                [System.XML.XMLElement]$ospf = $_LogicalRouterRouting.ownerDocument.CreateElement("ospf")
                $_LogicalRouterRouting.appendChild($ospf) | out-null
            }

            if ( $ospf.SelectSingleNode('child::enabled')) {
                #Enabled element exists.  Update it.
                $ospf.enabled = $EnableOSPF.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $ospf -xmlElementName "enabled" -xmlElementText $EnableOSPF.ToString().ToLower()
            }

            if ( $EnableOSPF -and (-not ($ProtocolAddress -or ($ospf.SelectSingleNode('child::protocolAddress'))))) {
                throw "ProtocolAddress and ForwardingAddress are required to enable OSPF"
            }

            if ( $EnableOSPF -and (-not ($ForwardingAddress -or ($ospf.SelectSingleNode('child::forwardingAddress'))))) {
                throw "ProtocolAddress and ForwardingAddress are required to enable OSPF"
            }

            if ( $PsBoundParameters.ContainsKey('ProtocolAddress') ) { 
                if ( $ospf.SelectSingleNode('child::protocolAddress')) {
                    # element exists.  Update it.
                    $ospf.protocolAddress = $ProtocolAddress.ToString().ToLower()
                }
                else {
                    #Enabled element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "protocolAddress" -xmlElementText $ProtocolAddress.ToString().ToLower()
                }
            }

            if ( $PsBoundParameters.ContainsKey('ForwardingAddress') ) { 
                if ( $ospf.SelectSingleNode('child::forwardingAddress')) {
                    # element exists.  Update it.
                    $ospf.forwardingAddress = $ForwardingAddress.ToString().ToLower()
                }
                else {
                    #Enabled element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "forwardingAddress" -xmlElementText $ForwardingAddress.ToString().ToLower()
                }
            }
        
        }

        if ( $PsBoundParameters.ContainsKey('EnableBGP')) {

            $bgp = $_LogicalRouterRouting.SelectSingleNode('child::bgp') 

            if ( -not $bgp ) {
                #bgp node does not exist.
                [System.XML.XMLElement]$bgp = $_LogicalRouterRouting.ownerDocument.CreateElement("bgp")
                $_LogicalRouterRouting.appendChild($bgp) | out-null

            }

            if ( $bgp.SelectSingleNode('child::enabled')) {
                #Enabled element exists.  Update it.
                $bgp.enabled = $EnableBGP.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $bgp -xmlElementName "enabled" -xmlElementText $EnableBGP.ToString().ToLower()
            }

            if ( $PsBoundParameters.ContainsKey("LocalAS")) { 
                if ( $bgp.SelectSingleNode('child::localAS')) {
                #LocalAS element exists, update it.
                    $bgp.localAS = $LocalAS.ToString()
                }
                else {
                    #LocalAS element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "localAS" -xmlElementText $LocalAS.ToString()
                }
            }
            elseif ( (-not ( $bgp.SelectSingleNode('child::localAS')) -and $EnableBGP  )) {
                throw "Existing configuration has no Local AS number specified.  Local AS must be set to enable BGP."
            }
            

        }

        if ( $PsBoundParameters.ContainsKey("EnableECMP")) { 
            $_LogicalRouterRouting.routingGlobalConfig.ecmp = $EnableECMP.ToString().ToLower()
        }


        if ( $PsBoundParameters.ContainsKey("EnableOspfRouteRedistribution")) { 

            $_LogicalRouterRouting.ospf.redistribution.enabled = $EnableOspfRouteRedistribution.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("EnableBgpRouteRedistribution")) { 
            if ( -not $_LogicalRouterRouting.SelectSingleNode('child::bgp/redistribution/enabled') ) {
                throw "BGP must have been configured at least once to enable/disable BGP route redistribution.  Enable BGP and try again."
            }

            $_LogicalRouterRouting.bgp.redistribution.enabled = $EnableBgpRouteRedistribution.ToString().ToLower()
        }


        if ( $PsBoundParameters.ContainsKey("EnableLogging")) { 
            $_LogicalRouterRouting.routingGlobalConfig.logging.enable = $EnableLogging.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("LogLevel")) { 
            $_LogicalRouterRouting.routingGlobalConfig.logging.logLevel = $LogLevel.ToString().ToLower()
        }

        if ( $PsBoundParameters.ContainsKey("DefaultGatewayVnic") -or $PsBoundParameters.ContainsKey("DefaultGatewayAddress") -or 
            $PsBoundParameters.ContainsKey("DefaultGatewayDescription") -or $PsBoundParameters.ContainsKey("DefaultGatewayMTU") -or
            $PsBoundParameters.ContainsKey("DefaultGatewayAdminDistance") ) { 

            #Check for and create if required the defaultRoute element. first.
            if ( -not $_LogicalRouterRouting.staticRouting.SelectSingleNode('child::defaultRoute')) {
                #defaultRoute element does not exist
                $defaultRoute = $_LogicalRouterRouting.ownerDocument.CreateElement('defaultRoute')
                $_LogicalRouterRouting.staticRouting.AppendChild($defaultRoute) | out-null
            }
            else {
                #defaultRoute element exists
                $defaultRoute = $_LogicalRouterRouting.staticRouting.defaultRoute
            }

            if ( $PsBoundParameters.ContainsKey("DefaultGatewayVnic") ) { 
                if ( -not $defaultRoute.SelectSingleNode('child::vnic')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "vnic" -xmlElementText $DefaultGatewayVnic.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.vnic = $DefaultGatewayVnic.ToString()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultGatewayAddress") ) { 
                if ( -not $defaultRoute.SelectSingleNode('child::gatewayAddress')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "gatewayAddress" -xmlElementText $DefaultGatewayAddress.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.gatewayAddress = $DefaultGatewayAddress.ToString()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultGatewayDescription") ) { 
                if ( -not $defaultRoute.SelectSingleNode('child::description')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "description" -xmlElementText $DefaultGatewayDescription
                }
                else {
                    #element exists
                    $defaultRoute.description = $DefaultGatewayDescription
                }
            }
            if ( $PsBoundParameters.ContainsKey("DefaultGatewayMTU") ) { 
                if ( -not $defaultRoute.SelectSingleNode('child::mtu')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "mtu" -xmlElementText $DefaultGatewayMTU.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.mtu = $DefaultGatewayMTU.ToString()
                }
            }
            if ( $PsBoundParameters.ContainsKey("DefaultGatewayAdminDistance") ) { 
                if ( -not $defaultRoute.SelectSingleNode('child::adminDistance')) {
                    #element does not exist
                    Add-XmlElement -xmlRoot $defaultRoute -xmlElementName "adminDistance" -xmlElementText $DefaultGatewayAdminDistance.ToString()
                }
                else {
                    #element exists
                    $defaultRoute.adminDistance = $DefaultGatewayAdminDistance.ToString()
                }
            }
        }


        $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
        $body = $_LogicalRouterRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
            $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxLogicalRouterRouting

function Get-NsxLogicalRouterRouting {
    
    <#
    .SYNOPSIS
    Retreives routing configuration for the spcified NSX LogicalRouter.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterRouting cmdlet retreives the routing configuration of
    the specified LogicalRouter.
    
    .EXAMPLE
    Get routing configuration for the LogicalRouter LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouter $_ })]
            [System.Xml.XmlElement]$LogicalRouter
    )
    
    begin {

    }

    process {
    
        #We append the LogicalRouter-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        $_LogicalRouterRouting = $LogicalRouter.features.routing.CloneNode($True)
        Add-XmlElement -xmlRoot $_LogicalRouterRouting -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouter.Id
        $_LogicalRouterRouting
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterRouting 

# Static Routing

function Get-NsxLogicalRouterStaticRoute {
    
    <#
    .SYNOPSIS
    Retreives Static Routes from the spcified NSX LogicalRouter Routing 
    configuration.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterStaticRoute cmdlet retreives the static routes from the 
    routing configuration specified.

    .EXAMPLE
    Get static routes defining on LogicalRouter LogicalRouter01

    PS C:\> Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterStaticRoute
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Network,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$NextHop       
        
    )
    
    begin {
    }

    process {
    
        #We append the LogicalRouter-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        $_LogicalRouterStaticRouting = ($LogicalRouterRouting.staticRouting.CloneNode($True))
        $LogicalRouterStaticRoutes = $_LogicalRouterStaticRouting.SelectSingleNode('child::staticRoutes')

        #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called route.
        If ( $LogicalRouterStaticRoutes.SelectSingleNode('child::route')) { 

            $RouteCollection = $LogicalRouterStaticRoutes.route
            if ( $PsBoundParameters.ContainsKey('Network')) {
                $RouteCollection = $RouteCollection | ? { $_.network -eq $Network }
            }

            if ( $PsBoundParameters.ContainsKey('NextHop')) {
                $RouteCollection = $RouteCollection | ? { $_.nextHop -eq $NextHop }
            }

            foreach ( $StaticRoute in $RouteCollection ) { 
                Add-XmlElement -xmlRoot $StaticRoute -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
            }

            $RouteCollection
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterStaticRoute

function New-NsxLogicalRouterStaticRoute {
    
    <#
    .SYNOPSIS
    Creates a new static route and adds it to the specified ESGs routing
    configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The New-NsxLogicalRouterStaticRoute cmdlet adds a new static route to the routing
    configuration of the specified LogicalRouter.

    .EXAMPLE
    Add a new static route to LogicalRouter LogicalRouter01 for 1.1.1.0/24 via 10.0.0.200

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterStaticRoute -Network 1.1.1.0/24 -NextHop 10.0.0.200
    
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,200)]
            [int]$Vnic,        
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,9128)]
            [int]$MTU,        
        [Parameter (Mandatory=$False)]
            [string]$Description,       
        [Parameter (Mandatory=$True)]
            [ipAddress]$NextHop,
        [Parameter (Mandatory=$True)]
            [string]$Network,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,255)]
            [int]$AdminDistance        
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        #Create the new route element.
        $Route = $_LogicalRouterRouting.ownerDocument.CreateElement('route')

        #Need to do an xpath query here rather than use PoSH dot notation to get the static route element,
        #as it might be empty, and PoSH silently turns an empty element into a string object, which is rather not what we want... :|
        $StaticRoutes = $_LogicalRouterRouting.staticRouting.SelectSingleNode('child::staticRoutes')
        $StaticRoutes.AppendChild($Route) | Out-Null

        Add-XmlElement -xmlRoot $Route -xmlElementName "network" -xmlElementText $Network.ToString()
        Add-XmlElement -xmlRoot $Route -xmlElementName "nextHop" -xmlElementText $NextHop.ToString()

        if ( $PsBoundParameters.ContainsKey("Vnic") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "vnic" -xmlElementText $Vnic.ToString()
        }

        if ( $PsBoundParameters.ContainsKey("MTU") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "mtu" -xmlElementText $MTU.ToString()
        }

        if ( $PsBoundParameters.ContainsKey("Description") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "description" -xmlElementText $Description.ToString()
        }
    
        if ( $PsBoundParameters.ContainsKey("AdminDistance") ) { 
            Add-XmlElement -xmlRoot $Route -xmlElementName "adminDistance" -xmlElementText $AdminDistance.ToString()
        }


        $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
        $body = $_LogicalRouterRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
            $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterStaticRoute -Network $Network -NextHop $NextHop
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterStaticRoute

function Remove-NsxLogicalRouterStaticRoute {
    
    <#
    .SYNOPSIS
    Removes a static route from the specified ESGs routing configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Remove-NsxLogicalRouterStaticRoute cmdlet removes a static route from the routing
    configuration of the specified LogicalRouter.

    Routes to be removed can be constructed via a PoSH pipline filter outputing
    route objects as produced by Get-NsxLogicalRouterStaticRoute and passing them on the
    pipeline to Remove-NsxLogicalRouterStaticRoute.

    .EXAMPLE
    Remove a route to 1.1.1.0/24 via 10.0.0.100 from LogicalRouter LogicalRouter01
    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterStaticRoute | ? { $_.network -eq '1.1.1.0/24' -and $_.nextHop -eq '10.0.0.100' } | Remove-NsxLogicalRouterStaticRoute

    .EXAMPLE
    Remove all routes to 1.1.1.0/24 from LogicalRouter LogicalRouter01
    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterStaticRoute | ? { $_.network -eq '1.1.1.0/24' } | Remove-NsxLogicalRouterStaticRoute

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterStaticRoute $_ })]
            [System.Xml.XmlElement]$StaticRoute,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our LogicalRouter
        $logicalrouterId = $StaticRoute.logicalrouterId
        $routing = Get-NsxLogicalRouter -objectId $logicalrouterId | Get-NsxLogicalRouterRouting

        #Remove the logicalrouterId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Need to do an xpath query here to query for a route that matches the one passed in.  
        #Union of nextHop and network should be unique
        $xpathQuery = "//staticRoutes/route[nextHop=`"$($StaticRoute.nextHop)`" and network=`"$($StaticRoute.network)`"]"
        write-debug "XPath query for route nodes to remove is: $xpathQuery"
        $RouteToRemove = $routing.staticRouting.SelectSingleNode($xpathQuery)

        if ( $RouteToRemove ) { 

            write-debug "RouteToRemove Element is: `n $($RouteToRemove.OuterXml | format-xml) "
            $routing.staticRouting.staticRoutes.RemoveChild($RouteToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            }
        }
        else {
            Throw "Route for network $($StaticRoute.network) via $($StaticRoute.nextHop) was not found in routing configuration for LogicalRouter $logicalrouterId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterStaticRoute

# Prefixes

function Get-NsxLogicalRouterPrefix {
    
    <#
    .SYNOPSIS
    Retreives IP Prefixes from the spcified NSX LogicalRouter Routing 
    configuration.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterPrefix cmdlet retreives IP prefixes from the 
    routing configuration specified.
    
    .EXAMPLE
    Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterPrefix

    Retrieve prefixes from LogicalRouter LogicalRouter01

    .EXAMPLE
    Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterPrefix -Network 1.1.1.0/24

    Retrieve prefix 1.1.1.0/24 from LogicalRouter LogicalRouter01

    .EXAMPLE
    Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterPrefix -Name CorpNet

    Retrieve prefix CorpNet from LogicalRouter LogicalRouter01
      
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Network       
        
    )
    
    begin {
    }

    process {
    
        #We append the LogicalRouter-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        $_GlobalRoutingConfig = ($LogicalRouterRouting.routingGlobalConfig.CloneNode($True))
        $IpPrefixes = $_GlobalRoutingConfig.SelectSingleNode('child::ipPrefixes')

        #IPPrefixes may not exist...
        if ( $IPPrefixes ) { 
            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called ipPrefix.
            If ( $IpPrefixes.SelectSingleNode('child::ipPrefix')) { 

                $PrefixCollection = $IPPrefixes.ipPrefix
                if ( $PsBoundParameters.ContainsKey('Network')) {
                    $PrefixCollection = $PrefixCollection | ? { $_.ipAddress -eq $Network }
                }

                if ( $PsBoundParameters.ContainsKey('Name')) {
                    $PrefixCollection = $PrefixCollection | ? { $_.name -eq $Name }
                }

                foreach ( $Prefix in $PrefixCollection ) { 
                    Add-XmlElement -xmlRoot $Prefix -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
                }

                $PrefixCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterPrefix

function New-NsxLogicalRouterPrefix {
    
    <#
    .SYNOPSIS
    Creates a new IP prefix and adds it to the specified ESGs routing
    configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The New-NsxLogicalRouterPrefix cmdlet adds a new IP prefix to the routing
    configuration of the specified LogicalRouter .

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$True)]
            [ValidateNotNullorEmpty()]
            [string]$Name,       
        [Parameter (Mandatory=$True)]
            [ValidateNotNullorEmpty()]
            [string]$Network      
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null


        #Need to do an xpath query here rather than use PoSH dot notation to get the IP prefix element,
        #as it might be empty or not exist, and PoSH silently turns an empty element into a string object, which is rather not what we want... :|
        $ipPrefixes = $_LogicalRouterRouting.routingGlobalConfig.SelectSingleNode('child::ipPrefixes')
        if ( -not $ipPrefixes ) { 
            #Create the ipPrefixes element
            $ipPrefixes = $_LogicalRouterRouting.ownerDocument.CreateElement('ipPrefixes')
            $_LogicalRouterRouting.routingGlobalConfig.AppendChild($ipPrefixes) | Out-Null
        }

        #Create the new ipPrefix element.
        $ipPrefix = $_LogicalRouterRouting.ownerDocument.CreateElement('ipPrefix')
        $ipPrefixes.AppendChild($ipPrefix) | Out-Null

        Add-XmlElement -xmlRoot $ipPrefix -xmlElementName "name" -xmlElementText $Name.ToString()
        Add-XmlElement -xmlRoot $ipPrefix -xmlElementName "ipAddress" -xmlElementText $Network.ToString()


        $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
        $body = $_LogicalRouterRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
            $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterPrefix -Network $Network -Name $Name
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterPrefix

function Remove-NsxLogicalRouterPrefix {
    
    <#
    .SYNOPSIS
    Removes an IP prefix from the specified ESGs routing configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Remove-NsxLogicalRouterPrefix cmdlet removes a IP prefix from the routing
    configuration of the specified LogicalRouter .

    Prefixes to be removed can be constructed via a PoSH pipline filter outputing
    prefix objects as produced by Get-NsxLogicalRouterPrefix and passing them on the
    pipeline to Remove-NsxLogicalRouterPrefix.

 

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterPrefix $_ })]
            [System.Xml.XmlElement]$Prefix,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our LogicalRouter
        $logicalrouterId = $Prefix.logicalrouterId
        $routing = Get-NsxLogicalRouter -objectId $logicalrouterId | Get-NsxLogicalRouterRouting

        #Remove the logicalrouterId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Need to do an xpath query here to query for a prefix that matches the one passed in.  
        #Union of nextHop and network should be unique
        $xpathQuery = "/routingGlobalConfig/ipPrefixes/ipPrefix[name=`"$($Prefix.name)`" and ipAddress=`"$($Prefix.ipAddress)`"]"
        write-debug "XPath query for prefix nodes to remove is: $xpathQuery"
        $PrefixToRemove = $routing.SelectSingleNode($xpathQuery)

        if ( $PrefixToRemove ) { 

            write-debug "PrefixToRemove Element is: `n $($PrefixToRemove.OuterXml | format-xml) "
            $routing.routingGlobalConfig.ipPrefixes.RemoveChild($PrefixToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            }
        }
        else {
            Throw "Prefix $($Prefix.Name) for network $($Prefix.network) was not found in routing configuration for LogicalRouter $logicalrouterId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterPrefix


# BGP

function Get-NsxLogicalRouterBgp {
    
    <#
    .SYNOPSIS
    Retreives BGP configuration for the specified NSX LogicalRouter.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterBgp cmdlet retreives the bgp configuration of
    the specified LogicalRouter.
    
    .EXAMPLE
    Get the BGP configuration for LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgp   
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting
    )
    
    begin {

    }

    process {
    
        #We append the LogicalRouter-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        if ( $LogicalRouterRouting.SelectSingleNode('child::bgp')) { 
            $bgp = $LogicalRouterRouting.SelectSingleNode('child::bgp').CloneNode($True)
            Add-XmlElement -xmlRoot $bgp -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
            $bgp
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterBgp

function Set-NsxLogicalRouterBgp {
    
    <#
    .SYNOPSIS
    Manipulates BGP specific base configuration of an existing NSX LogicalRouter.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Set-NsxLogicalRouterBgp cmdlet allows manipulation of the BGP specific configuration
    of a given ESG.
    
   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$EnableBGP,
        [Parameter (Mandatory=$False)]
            [IpAddress]$RouterId,
        [Parameter (Mandatory=$False)]
            [ValidateRange(0,65535)]
            [int]$LocalAS,
        [Parameter (Mandatory=$False)]
            [switch]$GracefulRestart,
        [Parameter (Mandatory=$False)]
            [switch]$DefaultOriginate

    )
    
    begin {

    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('EnableBGP') ) { 
            $xmlGlobalConfig = $_LogicalRouterRouting.routingGlobalConfig
            $xmlRouterId = $xmlGlobalConfig.SelectSingleNode('child::routerId')
            if ( $EnableBGP ) {
                if ( -not ($xmlRouterId -or $PsBoundParameters.ContainsKey("RouterId"))) {
                    #Existing config missing and no new value set...
                    throw "RouterId must be configured to enable dynamic routing"
                }

                if ($PsBoundParameters.ContainsKey("RouterId")) {
                    #Set Routerid...
                    if ($xmlRouterId) {
                        $xmlRouterId = $RouterId.IPAddresstoString
                    }
                    else{
                        Add-XmlElement -xmlRoot $xmlGlobalConfig -xmlElementName "routerId" -xmlElementText $RouterId.IPAddresstoString
                    }
                }
            }

            $bgp = $_LogicalRouterRouting.SelectSingleNode('child::bgp') 

            if ( -not $bgp ) {
                #bgp node does not exist.
                [System.XML.XMLElement]$bgp = $_LogicalRouterRouting.ownerDocument.CreateElement("bgp")
                $_LogicalRouterRouting.appendChild($bgp) | out-null
            }

            if ( $bgp.SelectSingleNode('child::enabled')) {
                #Enabled element exists.  Update it.
                $bgp.enabled = $EnableBGP.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $bgp -xmlElementName "enabled" -xmlElementText $EnableBGP.ToString().ToLower()
            }

            if ( $PsBoundParameters.ContainsKey("LocalAS")) { 
                if ( $bgp.SelectSingleNode('child::localAS')) {
                    #LocalAS element exists, update it.
                    $bgp.localAS = $LocalAS.ToString()
                }
                else {
                    #LocalAS element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "localAS" -xmlElementText $LocalAS.ToString()
                }
            }
            elseif ( (-not ( $bgp.SelectSingleNode('child::localAS')) -and $EnableBGP  )) {
                throw "Existing configuration has no Local AS number specified.  Local AS must be set to enable BGP."
            }

            if ( $PsBoundParameters.ContainsKey("GracefulRestart")) { 
                if ( $bgp.SelectSingleNode('child::gracefulRestart')) {
                    #element exists, update it.
                    $bgp.gracefulRestart = $GracefulRestart.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "gracefulRestart" -xmlElementText $GracefulRestart.ToString().ToLower()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultOriginate")) { 
                if ( $bgp.SelectSingleNode('child::defaultOriginate')) {
                    #element exists, update it.
                    $bgp.defaultOriginate = $DefaultOriginate.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $bgp -xmlElementName "defaultOriginate" -xmlElementText $DefaultOriginate.ToString().ToLower()
                }
            }
        }

        $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
        $body = $_LogicalRouterRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
            $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgp
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxLogicalRouterBgp

function Get-NsxLogicalRouterBgpNeighbour {
    
    <#
    .SYNOPSIS
    Returns BGP neighbours from the spcified NSX LogicalRouter BGP 
    configuration.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterBgpNeighbour cmdlet retreives the BGP neighbours from the 
    BGP configuration specified.

    .EXAMPLE
    Get all BGP neighbours defined on LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgpNeighbour
    
    .EXAMPLE
    Get BGP neighbour 1.1.1.1 defined on LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgpNeighbour -IpAddress 1.1.1.1

    .EXAMPLE
    Get all BGP neighbours with Remote AS 1234 defined on LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgpNeighbour | ? { $_.RemoteAS -eq '1234' }

    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [String]$Network,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$IpAddress,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,65535)]
            [int]$RemoteAS              
    )
    
    begin {
    }

    process {
    
        $bgp = $LogicalRouterRouting.SelectSingleNode('child::bgp')

        if ( $bgp ) {

            $_bgp = $bgp.CloneNode($True)
            $BgpNeighbours = $_bgp.SelectSingleNode('child::bgpNeighbours')


            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called bgpNeighbour.
            if ( $BgpNeighbours.SelectSingleNode('child::bgpNeighbour')) { 

                $NeighbourCollection = $BgpNeighbours.bgpNeighbour
                if ( $PsBoundParameters.ContainsKey('IpAddress')) {
                    $NeighbourCollection = $NeighbourCollection | ? { $_.ipAddress -eq $IpAddress }
                }

                if ( $PsBoundParameters.ContainsKey('RemoteAS')) {
                    $NeighbourCollection = $NeighbourCollection | ? { $_.remoteAS -eq $RemoteAS }
                }

                foreach ( $Neighbour in $NeighbourCollection ) { 
                    #We append the LogicalRouter-id to the associated neighbour config XML to enable pipeline workflows and 
                    #consistent readable output
                    Add-XmlElement -xmlRoot $Neighbour -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
                }

                $NeighbourCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterBgpNeighbour

function New-NsxLogicalRouterBgpNeighbour {
    
    <#
    .SYNOPSIS
    Creates a new BGP neighbour and adds it to the specified ESGs BGP
    configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The New-NsxLogicalRouterBgpNeighbour cmdlet adds a new BGP neighbour to the 
    bgp configuration of the specified LogicalRouter.

    .EXAMPLE
    Add a new neighbour 1.2.3.4 with remote AS number 1234 with defaults.

    PS C:\> Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterBgpNeighbour -IpAddress 1.2.3.4 -RemoteAS 1234 -ForwardingAddress 1.2.3.1 -ProtocolAddress 1.2.3.2

    .EXAMPLE
    Add a new neighbour 1.2.3.4 with remote AS number 22235 specifying weight, holddown and keepalive timers and dont prompt for confirmation.

    PS C:\> Get-NsxLogicalRouter | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterBgpNeighbour -IpAddress 1.2.3.4 -RemoteAS 22235 -ForwardingAddress 1.2.3.1 -ProtocolAddress 1.2.3.2 -Confirm:$false -Weight 90 -HoldDownTimer 240 -KeepAliveTimer 90 -confirm:$false

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$IpAddress,
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,65535)]
            [int]$RemoteAS,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$ForwardingAddress,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$ProtocolAddress,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,65535)]
            [int]$Weight,
        [Parameter (Mandatory=$false)]
            [ValidateRange(2,65535)]
            [int]$HoldDownTimer,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65534)]
            [int]$KeepAliveTimer,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [string]$Password     
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Create the new bgpNeighbour element.
        $Neighbour = $_LogicalRouterRouting.ownerDocument.CreateElement('bgpNeighbour')

        #Need to do an xpath query here rather than use PoSH dot notation to get the bgp element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $bgp = $_LogicalRouterRouting.SelectSingleNode('child::bgp')
        if ( $bgp ) { 
            $bgp.selectSingleNode('child::bgpNeighbours').AppendChild($Neighbour) | Out-Null

            Add-XmlElement -xmlRoot $Neighbour -xmlElementName "ipAddress" -xmlElementText $IpAddress.ToString()
            Add-XmlElement -xmlRoot $Neighbour -xmlElementName "remoteAS" -xmlElementText $RemoteAS.ToString()
            Add-XmlElement -xmlRoot $Neighbour -xmlElementName "forwardingAddress" -xmlElementText $ForwardingAddress.ToString()
            Add-XmlElement -xmlRoot $Neighbour -xmlElementName "protocolAddress" -xmlElementText $ProtocolAddress.ToString()


            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey("Weight") ) { 
                Add-XmlElement -xmlRoot $Neighbour -xmlElementName "weight" -xmlElementText $Weight.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("HoldDownTimer") ) { 
                Add-XmlElement -xmlRoot $Neighbour -xmlElementName "holdDownTimer" -xmlElementText $HoldDownTimer.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("KeepAliveTimer") ) { 
                Add-XmlElement -xmlRoot $Neighbour -xmlElementName "keepAliveTimer" -xmlElementText $KeepAliveTimer.ToString()
            }


            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $_LogicalRouterRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
                Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgpNeighbour -IpAddress $IpAddress -RemoteAS $RemoteAS
            }
        }
        else {
            throw "BGP is not enabled on logicalrouter $logicalrouterID.  Enable BGP using Set-NsxLogicalRouterRouting or Set-NsxLogicalRouterBGP first."
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterBgpNeighbour

function Remove-NsxLogicalRouterBgpNeighbour {
    
    <#
    .SYNOPSIS
    Removes a BGP neigbour from the specified ESGs BGP configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Remove-NsxLogicalRouterBgpNeighbour cmdlet removes a BGP neighbour route from the 
    bgp configuration of the specified LogicalRouter Services Gateway.

    Neighbours to be removed can be constructed via a PoSH pipline filter outputing
    neighbour objects as produced by Get-NsxLogicalRouterBgpNeighbour and passing them on the
    pipeline to Remove-NsxLogicalRouterBgpNeighbour.

    .EXAMPLE
    Remove the BGP neighbour 1.1.1.2 from the the logicalrouter LogicalRouter01's bgp configuration

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterBgpNeighbour | ? { $_.ipaddress -eq '1.1.1.2' } |  Remove-NsxLogicalRouterBgpNeighbour 
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterBgpNeighbour $_ })]
            [System.Xml.XmlElement]$BgpNeighbour,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our LogicalRouter
        $logicalrouterId = $BgpNeighbour.logicalrouterId
        $routing = Get-NsxLogicalRouter -objectId $logicalrouterId | Get-NsxLogicalRouterRouting

        #Remove the logicalrouterId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Validate the BGP node exists on the logicalrouter 
        if ( -not $routing.SelectSingleNode('child::bgp')) { throw "BGP is not enabled on ESG $logicalrouterId.  Enable BGP and try again." }

        #Need to do an xpath query here to query for a bgp neighbour that matches the one passed in.  
        #Union of ipaddress and remote AS should be unique (though this is not enforced by the API, 
        #I cant see why having duplicate neighbours with same ip and AS would be useful...maybe 
        #different filters?)
        #Will probably need to include additional xpath query filters here in the query to include 
        #matching on filters to better handle uniquness amongst bgp neighbours with same ip and remoteAS

        $xpathQuery = "//bgpNeighbours/bgpNeighbour[ipAddress=`"$($BgpNeighbour.ipAddress)`" and remoteAS=`"$($BgpNeighbour.remoteAS)`"]"
        write-debug "XPath query for neighbour nodes to remove is: $xpathQuery"
        $NeighbourToRemove = $routing.bgp.SelectSingleNode($xpathQuery)

        if ( $NeighbourToRemove ) { 

            write-debug "NeighbourToRemove Element is: `n $($NeighbourToRemove.OuterXml | format-xml) "
            $routing.bgp.bgpNeighbours.RemoveChild($NeighbourToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            }
        }
        else {
            Throw "Neighbour $($BgpNeighbour.ipAddress) with Remote AS $($BgpNeighbour.RemoteAS) was not found in routing configuration for LogicalRouter $logicalrouterId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterBgpNeighbour

# OSPF

function Get-NsxLogicalRouterOspf {
    
    <#
    .SYNOPSIS
    Retreives OSPF configuration for the spcified NSX LogicalRouter.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterOspf cmdlet retreives the OSPF configuration of
    the specified LogicalRouter.
    
    .EXAMPLE
    Get the OSPF configuration for LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspf
    
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting
    )
    
    begin {

    }

    process {
    
        #We append the LogicalRouter-id to the associated Routing config XML to enable pipeline workflows and 
        #consistent readable output

        if ( $LogicalRouterRouting.SelectSingleNode('child::ospf')) { 
            $ospf = $LogicalRouterRouting.ospf.CloneNode($True)
            Add-XmlElement -xmlRoot $ospf -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
            $ospf
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterOspf

function Set-NsxLogicalRouterOspf {
    
    <#
    .SYNOPSIS
    Manipulates OSPF specific base configuration of an existing NSX 
    LogicalRouter.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Set-NsxLogicalRouterOspf cmdlet allows manipulation of the OSPF specific 
    configuration of a given ESG.
    
   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$EnableOSPF,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$ProtocolAddress,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [ipAddress]$ForwardingAddress,
        [Parameter (Mandatory=$False)]
            [IpAddress]$RouterId,
        [Parameter (Mandatory=$False)]
            [switch]$GracefulRestart,
        [Parameter (Mandatory=$False)]
            [switch]$DefaultOriginate

    )
    
    begin {

    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('EnableOSPF') ) { 
            $xmlGlobalConfig = $_LogicalRouterRouting.routingGlobalConfig
            $xmlRouterId = $xmlGlobalConfig.SelectSingleNode('child::routerId')
            if ( $EnableOSPF ) {
                if ( -not ($xmlRouterId -or $PsBoundParameters.ContainsKey("RouterId"))) {
                    #Existing config missing and no new value set...
                    throw "RouterId must be configured to enable dynamic routing"
                }

                if ($PsBoundParameters.ContainsKey("RouterId")) {
                    #Set Routerid...
                    if ($xmlRouterId) {
                        $xmlRouterId = $RouterId.IPAddresstoString
                    }
                    else{
                        Add-XmlElement -xmlRoot $xmlGlobalConfig -xmlElementName "routerId" -xmlElementText $RouterId.IPAddresstoString
                    }
                }
            }


            $ospf = $_LogicalRouterRouting.SelectSingleNode('child::ospf') 

            if ( $EnableOSPF -and (-not ($ProtocolAddress -or ($ospf.SelectSingleNode('child::protocolAddress'))))) {
                throw "ProtocolAddress and ForwardingAddress are required to enable OSPF"
            }

            if ( $EnableOSPF -and (-not ($ForwardingAddress -or ($ospf.SelectSingleNode('child::forwardingAddress'))))) {
                throw "ProtocolAddress and ForwardingAddress are required to enable OSPF"
            }

            if ( $PsBoundParameters.ContainsKey('ProtocolAddress') ) { 
                if ( $ospf.SelectSingleNode('child::protocolAddress')) {
                    # element exists.  Update it.
                    $ospf.protocolAddress = $ProtocolAddress.ToString().ToLower()
                }
                else {
                    #Enabled element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "protocolAddress" -xmlElementText $ProtocolAddress.ToString().ToLower()
                }
            }

            if ( $PsBoundParameters.ContainsKey('ForwardingAddress') ) { 
                if ( $ospf.SelectSingleNode('child::forwardingAddress')) {
                    # element exists.  Update it.
                    $ospf.forwardingAddress = $ForwardingAddress.ToString().ToLower()
                }
                else {
                    #Enabled element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "forwardingAddress" -xmlElementText $ForwardingAddress.ToString().ToLower()
                }
            }

            if ( -not $ospf ) {
                #ospf node does not exist.
                [System.XML.XMLElement]$ospf = $_LogicalRouterRouting.ownerDocument.CreateElement("ospf")
                $_LogicalRouterRouting.appendChild($ospf) | out-null
            }

            if ( $ospf.SelectSingleNode('child::enabled')) {
                #Enabled element exists.  Update it.
                $ospf.enabled = $EnableOSPF.ToString().ToLower()
            }
            else {
                #Enabled element does not exist...
                Add-XmlElement -xmlRoot $ospf -xmlElementName "enabled" -xmlElementText $EnableOSPF.ToString().ToLower()
            }

            if ( $PsBoundParameters.ContainsKey("GracefulRestart")) { 
                if ( $ospf.SelectSingleNode('child::gracefulRestart')) {
                    #element exists, update it.
                    $ospf.gracefulRestart = $GracefulRestart.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "gracefulRestart" -xmlElementText $GracefulRestart.ToString().ToLower()
                }
            }

            if ( $PsBoundParameters.ContainsKey("DefaultOriginate")) { 
                if ( $ospf.SelectSingleNode('child::defaultOriginate')) {
                    #element exists, update it.
                    $ospf.defaultOriginate = $DefaultOriginate.ToString().ToLower()
                }
                else {
                    #element does not exist...
                    Add-XmlElement -xmlRoot $ospf -xmlElementName "defaultOriginate" -xmlElementText $DefaultOriginate.ToString().ToLower()
                }
            }
        }

        $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
        $body = $_LogicalRouterRouting.OuterXml 
       
        
        if ( $confirm ) { 
            $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
            $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }    
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspf
        }
    }

    end {}
}
Export-ModuleMember -Function Set-NsxLogicalRouterOspf

function Get-NsxLogicalRouterOspfArea {
    
    <#
    .SYNOPSIS
    Returns OSPF Areas defined in the spcified NSX LogicalRouter OSPF 
    configuration.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterOspfArea cmdlet retreives the OSPF Areas from the OSPF 
    configuration specified.

    .EXAMPLE
    Get all areas defined on LogicalRouter01.

    PS C:\> C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfArea 
    
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,4294967295)]
            [int]$AreaId              
    )
    
    begin {
    }

    process {
    
        $ospf = $LogicalRouterRouting.SelectSingleNode('child::ospf')

        if ( $ospf ) {

            $_ospf = $ospf.CloneNode($True)
            $OspfAreas = $_ospf.SelectSingleNode('child::ospfAreas')


            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called ospfArea.
            if ( $OspfAreas.SelectSingleNode('child::ospfArea')) { 

                $AreaCollection = $OspfAreas.ospfArea
                if ( $PsBoundParameters.ContainsKey('AreaId')) {
                    $AreaCollection = $AreaCollection | ? { $_.areaId -eq $AreaId }
                }

                foreach ( $Area in $AreaCollection ) { 
                    #We append the LogicalRouter-id to the associated Area config XML to enable pipeline workflows and 
                    #consistent readable output
                    Add-XmlElement -xmlRoot $Area -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
                }

                $AreaCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterOspfArea

function Remove-NsxLogicalRouterOspfArea {
    
    <#
    .SYNOPSIS
    Removes an OSPF area from the specified ESGs OSPF configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Remove-NsxLogicalRouterOspfArea cmdlet removes a BGP neighbour route from the 
    bgp configuration of the specified LogicalRouter.

    Areas to be removed can be constructed via a PoSH pipline filter outputing
    area objects as produced by Get-NsxLogicalRouterOspfArea and passing them on the
    pipeline to Remove-NsxLogicalRouterOspfArea.
    
    .EXAMPLE
    Remove area 51 from ospf configuration on LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfArea -AreaId 51 | Remove-NsxLogicalRouterOspfArea
    
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterOspfArea $_ })]
            [System.Xml.XmlElement]$OspfArea,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our LogicalRouter
        $logicalrouterId = $OspfArea.logicalrouterId
        $routing = Get-NsxLogicalRouter -objectId $logicalrouterId | Get-NsxLogicalRouterRouting

        #Remove the logicalrouterId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Validate the OSPF node exists on the logicalrouter 
        if ( -not $routing.SelectSingleNode('child::ospf')) { throw "OSPF is not enabled on ESG $logicalrouterId.  Enable OSPF and try again." }
        if ( -not ($routing.ospf.enabled -eq 'true') ) { throw "OSPF is not enabled on ESG $logicalrouterId.  Enable OSPF and try again." }

        

        $xpathQuery = "//ospfAreas/ospfArea[areaId=`"$($OspfArea.areaId)`"]"
        write-debug "XPath query for area nodes to remove is: $xpathQuery"
        $AreaToRemove = $routing.ospf.SelectSingleNode($xpathQuery)

        if ( $AreaToRemove ) { 

            write-debug "AreaToRemove Element is: `n $($AreaToRemove.OuterXml | format-xml) "
            $routing.ospf.ospfAreas.RemoveChild($AreaToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            }
        }
        else {
            Throw "Area $($OspfArea.areaId) was not found in routing configuration for LogicalRouter $logicalrouterId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterOspfArea

function New-NsxLogicalRouterOspfArea {
    
    <#
    .SYNOPSIS
    Creates a new OSPF Area and adds it to the specified ESGs OSPF 
    configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The New-NsxLogicalRouterOspfArea cmdlet adds a new OSPF Area to the ospf
    configuration of the specified LogicalRouter.

    .EXAMPLE
    Create area 50 as a normal type on ESG LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterOspfArea -AreaId 50

    .EXAMPLE
    Create area 10 as a nssa type on ESG LogicalRouter01 with password authentication

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterOspfArea -AreaId 10 -Type password -Password "Secret"


   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,4294967295)]
            [uint32]$AreaId,
        [Parameter (Mandatory=$false)]
            [ValidateSet("normal","nssa",IgnoreCase = $false)]
            [string]$Type,
        [Parameter (Mandatory=$false)]
            [ValidateSet("none","password","md5",IgnoreCase = $false)]
            [string]$AuthenticationType="none",
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [string]$Password
    )
    
    begin {
    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Create the new ospfArea element.
        $Area = $_LogicalRouterRouting.ownerDocument.CreateElement('ospfArea')

        #Need to do an xpath query here rather than use PoSH dot notation to get the ospf element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $ospf = $_LogicalRouterRouting.SelectSingleNode('child::ospf')
        if ( $ospf ) { 
            $ospf.selectSingleNode('child::ospfAreas').AppendChild($Area) | Out-Null

            Add-XmlElement -xmlRoot $Area -xmlElementName "areaId" -xmlElementText $AreaId.ToString()

            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey("Type") ) { 
                Add-XmlElement -xmlRoot $Area -xmlElementName "type" -xmlElementText $Type.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("AuthenticationType") -or $PsBoundParameters.ContainsKey("Password") ) { 
                switch ($AuthenticationType) {

                    "none" { 
                        if ( $PsBoundParameters.ContainsKey('Password') ) { 
                            throw "Authentication type must be other than none to specify a password."
                        }
                        #Default value - do nothing
                    }

                    default { 
                        if ( -not ( $PsBoundParameters.ContainsKey('Password')) ) {
                            throw "Must specify a password if Authentication type is not none."
                        }
                        $Authentication = $Area.ownerDocument.CreateElement("authentication")
                        $Area.AppendChild( $Authentication ) | out-null

                        Add-XmlElement -xmlRoot $Authentication -xmlElementName "type" -xmlElementText $AuthenticationType
                        Add-XmlElement -xmlRoot $Authentication -xmlElementName "value" -xmlElementText $Password
                    }
                }
            }

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $_LogicalRouterRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
                Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfArea -AreaId $AreaId
            }
        }
        else {
            throw "OSPF is not enabled on logicalrouter $logicalrouterID.  Enable OSPF using Set-NsxLogicalRouterRouting or Set-NsxLogicalRouterOSPF first."
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterOspfArea

function Get-NsxLogicalRouterOspfInterface {
    
    <#
    .SYNOPSIS
    Returns OSPF Interface mappings defined in the spcified NSX LogicalRouter 
    OSPF configuration.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Get-NsxLogicalRouterOspfInterface cmdlet retreives the OSPF Area to interfaces 
    mappings from the OSPF configuration specified.

    .EXAMPLE
    Get all OSPF Area to Interface mappings on LogicalRouter LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfInterface
   
    .EXAMPLE
    Get OSPF Area to Interface mapping for Area 10 on LogicalRouter LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfInterface -AreaId 10
   
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,4294967295)]
            [int]$AreaId,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,200)]
            [int]$vNicId    
    )
    
    begin {
    }

    process {
    
        $ospf = $LogicalRouterRouting.SelectSingleNode('child::ospf')

        if ( $ospf ) {

            $_ospf = $ospf.CloneNode($True)
            $OspfInterfaces = $_ospf.SelectSingleNode('child::ospfInterfaces')


            #Need to use an xpath query here, as dot notation will throw in strict mode if there is not childnode called ospfArea.
            if ( $OspfInterfaces.SelectSingleNode('child::ospfInterface')) { 

                $InterfaceCollection = $OspfInterfaces.ospfInterface
                if ( $PsBoundParameters.ContainsKey('AreaId')) {
                    $InterfaceCollection = $InterfaceCollection | ? { $_.areaId -eq $AreaId }
                }

                if ( $PsBoundParameters.ContainsKey('vNicId')) {
                    $InterfaceCollection = $InterfaceCollection | ? { $_.vnic -eq $vNicId }
                }

                foreach ( $Interface in $InterfaceCollection ) { 
                    #We append the LogicalRouter-id to the associated Area config XML to enable pipeline workflows and 
                    #consistent readable output
                    Add-XmlElement -xmlRoot $Interface -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId
                }

                $InterfaceCollection
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterOspfInterface

function Remove-NsxLogicalRouterOspfInterface {
    
    <#
    .SYNOPSIS
    Removes an OSPF Interface from the specified ESGs OSPF configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Remove-NsxLogicalRouterOspfInterface cmdlet removes a BGP neighbour route from 
    the bgp configuration of the specified LogicalRouter.

    Interfaces to be removed can be constructed via a PoSH pipline filter 
    outputing interface objects as produced by Get-NsxLogicalRouterOspfInterface and 
    passing them on the pipeline to Remove-NsxLogicalRouterOspfInterface.
    
    .EXAMPLE
    Remove Interface to Area mapping for area 51 from LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfInterface -AreaId 51 | Remove-NsxLogicalRouterOspfInterface

    .EXAMPLE
    Remove all Interface to Area mappings from LogicalRouter01 without confirmation.

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfInterface | Remove-NsxLogicalRouterOspfInterface -confirm:$false

    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterOspfInterface $_ })]
            [System.Xml.XmlElement]$OspfInterface,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our LogicalRouter
        $logicalrouterId = $OspfInterface.logicalrouterId
        $routing = Get-NsxLogicalRouter -objectId $logicalrouterId | Get-NsxLogicalRouterRouting

        #Remove the logicalrouterId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Validate the OSPF node exists on the logicalrouter 
        if ( -not $routing.SelectSingleNode('child::ospf')) { throw "OSPF is not enabled on ESG $logicalrouterId.  Enable OSPF and try again." }
        if ( -not ($routing.ospf.enabled -eq 'true') ) { throw "OSPF is not enabled on ESG $logicalrouterId.  Enable OSPF and try again." }

        

        $xpathQuery = "//ospfInterfaces/ospfInterface[areaId=`"$($OspfInterface.areaId)`"]"
        write-debug "XPath query for interface nodes to remove is: $xpathQuery"
        $InterfaceToRemove = $routing.ospf.SelectSingleNode($xpathQuery)

        if ( $InterfaceToRemove ) { 

            write-debug "InterfaceToRemove Element is: `n $($InterfaceToRemove.OuterXml | format-xml) "
            $routing.ospf.ospfInterfaces.RemoveChild($InterfaceToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            }
        }
        else {
            Throw "Interface $($OspfInterface.areaId) was not found in routing configuration for LogicalRouter $logicalrouterId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterOspfInterface

function New-NsxLogicalRouterOspfInterface {
    
    <#
    .SYNOPSIS
    Creates a new OSPF Interface to Area mapping and adds it to the specified 
    LogicalRouters OSPF configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The New-NsxLogicalRouterOspfInterface cmdlet adds a new OSPF Area to Interface 
    mapping to the ospf configuration of the specified LogicalRouter.

    .EXAMPLE
    Add a mapping for Area 10 to Interface 0 on ESG LogicalRouter01

    PS C:\> Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterOspfInterface -AreaId 10 -Vnic 0
   
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,4294967295)]
            [uint32]$AreaId,
        [Parameter (Mandatory=$true)]
            [ValidateRange(0,200)]
            [int]$Vnic,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,255)]
            [int]$HelloInterval,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65535)]
            [int]$DeadInterval,
        [Parameter (Mandatory=$false)]
            [ValidateRange(0,255)]
            [int]$Priority,
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65535)]
            [int]$Cost,
        [Parameter (Mandatory=$false)]
            [switch]$IgnoreMTU

    )

    
    begin {
    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Create the new ospfInterface element.
        $Interface = $_LogicalRouterRouting.ownerDocument.CreateElement('ospfInterface')

        #Need to do an xpath query here rather than use PoSH dot notation to get the ospf element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $ospf = $_LogicalRouterRouting.SelectSingleNode('child::ospf')
        if ( $ospf ) { 
            $ospf.selectSingleNode('child::ospfInterfaces').AppendChild($Interface) | Out-Null

            Add-XmlElement -xmlRoot $Interface -xmlElementName "areaId" -xmlElementText $AreaId.ToString()
            Add-XmlElement -xmlRoot $Interface -xmlElementName "vnic" -xmlElementText $Vnic.ToString()

            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey("HelloInterval") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "helloInterval" -xmlElementText $HelloInterval.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("DeadInterval") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "deadInterval" -xmlElementText $DeadInterval.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("Priority") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "priority" -xmlElementText $Priority.ToString()
            }
            
            if ( $PsBoundParameters.ContainsKey("Cost") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "cost" -xmlElementText $Cost.ToString()
            }

            if ( $PsBoundParameters.ContainsKey("IgnoreMTU") ) { 
                Add-XmlElement -xmlRoot $Interface -xmlElementName "mtuIgnore" -xmlElementText $IgnoreMTU.ToString().ToLower()
            }

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $_LogicalRouterRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
                Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterOspfInterface -AreaId $AreaId
            }
        }
        else {
            throw "OSPF is not enabled on logicalrouter $logicalrouterID.  Enable OSPF using Set-NsxLogicalRouterRouting or Set-NsxLogicalRouterOSPF first."
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterOspfInterface

# Redistribution Rules

function Get-NsxLogicalRouterRedistributionRule {
    
    <#
    .SYNOPSIS
    Returns dynamic route redistribution rules defined in the spcified NSX 
    LogicalRouter routing configuration.

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.
    The Get-NsxLogicalRouterRedistributionRule cmdlet retreives the route 
    redistribution rules defined in the ospf and bgp configurations for the 
    specified LogicalRouter.

    .EXAMPLE
    Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterRedistributionRule -Learner ospf

    Get all Redistribution rules for ospf on LogicalRouter LogicalRouter01
    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,
        [Parameter (Mandatory=$false)]
            [ValidateSet("ospf","bgp")]
            [string]$Learner,
        [Parameter (Mandatory=$false)]
            [int]$Id
    )
    
    begin {
    }

    process {
    
        #Rules can be defined in either ospf or bgp (isis as well, but who cares huh? :) )
        if ( ( -not $PsBoundParameters.ContainsKey('Learner')) -or ($PsBoundParameters.ContainsKey('Learner') -and $Learner -eq 'ospf')) {

            $ospf = $LogicalRouterRouting.SelectSingleNode('child::ospf')

            if ( $ospf ) {

                $_ospf = $ospf.CloneNode($True)
                if ( $_ospf.SelectSingleNode('child::redistribution/rules/rule') ) { 

                    $OspfRuleCollection = $_ospf.redistribution.rules.rule

                    foreach ( $rule in $OspfRuleCollection ) { 
                        #We append the LogicalRouter-id to the associated rule config XML to enable pipeline workflows and 
                        #consistent readable output
                        Add-XmlElement -xmlRoot $rule -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId

                        #Add the learner to be consistent with the view the UI gives
                        Add-XmlElement -xmlRoot $rule -xmlElementName "learner" -xmlElementText "ospf"

                    }

                    if ( $PsBoundParameters.ContainsKey('Id')) {
                        $OspfRuleCollection = $OspfRuleCollection | ? { $_.id -eq $Id }
                    }

                    $OspfRuleCollection
                }
            }
        }

        if ( ( -not $PsBoundParameters.ContainsKey('Learner')) -or ($PsBoundParameters.ContainsKey('Learner') -and $Learner -eq 'bgp')) {

            $bgp = $LogicalRouterRouting.SelectSingleNode('child::bgp')
            if ( $bgp ) {

                $_bgp = $bgp.CloneNode($True)
                if ( $_bgp.SelectSingleNode('child::redistribution/rules') ) { 

                    $BgpRuleCollection = $_bgp.redistribution.rules.rule

                    foreach ( $rule in $BgpRuleCollection ) { 
                        #We append the LogicalRouter-id to the associated rule config XML to enable pipeline workflows and 
                        #consistent readable output
                        Add-XmlElement -xmlRoot $rule -xmlElementName "logicalrouterId" -xmlElementText $LogicalRouterRouting.LogicalRouterId

                        #Add the learner to be consistent with the view the UI gives
                        Add-XmlElement -xmlRoot $rule -xmlElementName "learner" -xmlElementText "bgp"
                    }

                    if ( $PsBoundParameters.ContainsKey('Id')) {
                        $BgpRuleCollection = $BgpRuleCollection | ? { $_.id -eq $Id }
                    }
                    $BgpRuleCollection
                }
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxLogicalRouterRedistributionRule

function Remove-NsxLogicalRouterRedistributionRule {
    
    <#
    .SYNOPSIS
    Removes a route redistribution rule from the specified LogicalRouters
    configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The Remove-NsxLogicalRouterRedistributionRule cmdlet removes a route 
    redistribution rule from the configuration of the specified LogicalRouter.

    Interfaces to be removed can be constructed via a PoSH pipline filter 
    outputing interface objects as produced by 
    Get-NsxLogicalRouterRedistributionRule and passing them on the pipeline to 
    Remove-NsxLogicalRouterRedistributionRule.
  
    .EXAMPLE
    Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterRedistributionRule -Learner ospf | Remove-NsxLogicalRouterRedistributionRule

    Remove all ospf redistribution rules from LogicalRouter01
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRedistributionRule $_ })]
            [System.Xml.XmlElement]$RedistributionRule,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true        
    )
    
    begin {
    }

    process {

        #Get the routing config for our LogicalRouter
        $logicalrouterId = $RedistributionRule.logicalrouterId
        $routing = Get-NsxLogicalRouter -objectId $logicalrouterId | Get-NsxLogicalRouterRouting

        #Remove the logicalrouterId element from the XML as we need to post it...
        $routing.RemoveChild( $($routing.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Validate the learner protocol node exists on the logicalrouter 
        if ( -not $routing.SelectSingleNode("child::$($RedistributionRule.learner)")) {
            throw "Rule learner protocol $($RedistributionRule.learner) is not enabled on LogicalRouter $logicalrouterId.  Use Get-NsxLogicalRouter <this logicalrouter> | Get-NsxLogicalRouterrouting | Get-NsxLogicalRouterRedistributionRule to get the rule you want to remove." 
        }

        #Make XPath do all the hard work... Wish I was able to just compare the from node, but id doesnt appear possible with xpath 1.0
        $xpathQuery = "child::$($RedistributionRule.learner)/redistribution/rules/rule[action=`"$($RedistributionRule.action)`""
        $xPathQuery += " and from/connected=`"$($RedistributionRule.from.connected)`" and from/static=`"$($RedistributionRule.from.static)`""
        $xPathQuery += " and from/ospf=`"$($RedistributionRule.from.ospf)`" and from/bgp=`"$($RedistributionRule.from.bgp)`""
        $xPathQuery += " and from/isis=`"$($RedistributionRule.from.isis)`""

        if ( $RedistributionRule.SelectSingleNode('child::prefixName')) { 

            $xPathQuery += " and prefixName=`"$($RedistributionRule.prefixName)`""
        }
        
        $xPathQuery += "]"

        write-debug "XPath query for rule node to remove is: $xpathQuery"
        
        $RuleToRemove = $routing.SelectSingleNode($xpathQuery)

        if ( $RuleToRemove ) { 

            write-debug "RuleToRemove Element is: `n $($RuleToRemove | format-xml) "
            $routing.$($RedistributionRule.Learner).redistribution.rules.RemoveChild($RuleToRemove) | Out-Null

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $routing.OuterXml 
       
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
            }
        }
        else {
            Throw "Rule Id $($RedistributionRule.Id) was not found in the $($RedistributionRule.Learner) routing configuration for LogicalRouter $logicalrouterId"
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLogicalRouterRedistributionRule

function New-NsxLogicalRouterRedistributionRule {
    
    <#
    .SYNOPSIS
    Creates a new route redistribution rule and adds it to the specified 
    LogicalRouters configuration. 

    .DESCRIPTION
    An NSX Logical Router is a distributed routing function implemented within
    the ESXi kernel, and optimised for east west routing.

    Logical Routers perform ipv4 and ipv6 routing functions for connected
    networks and support both static and dynamic routing via OSPF and BGP.

    The New-NsxLogicalRouterRedistributionRule cmdlet adds a new route 
    redistribution rule to the configuration of the specified LogicalRouter.

    .EXAMPLE
    Get-NsxLogicalRouter LogicalRouter01 | Get-NsxLogicalRouterRouting | New-NsxLogicalRouterRedistributionRule -PrefixName test -Learner ospf -FromConnected -FromStatic -Action permit

    Create a new permit Redistribution Rule for prefix test (note, prefix must already exist, and is case sensistive) for ospf.
    #>

 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LogicalRouterRouting $_ })]
            [System.Xml.XmlElement]$LogicalRouterRouting,    
        [Parameter (Mandatory=$True)]
            [ValidateSet("ospf","bgp",IgnoreCase=$false)]
            [String]$Learner,
        [Parameter (Mandatory=$false)]
            [String]$PrefixName,    
        [Parameter (Mandatory=$false)]
            [switch]$FromConnected,
        [Parameter (Mandatory=$false)]
            [switch]$FromStatic,
        [Parameter (Mandatory=$false)]
            [switch]$FromOspf,
        [Parameter (Mandatory=$false)]
            [switch]$FromBgp,
        [Parameter (Mandatory=$False)]
            [ValidateSet("permit","deny",IgnoreCase=$false)]
            [String]$Action="permit",  
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$true  

    )

    
    begin {
    }

    process {

        #Create private xml element
        $_LogicalRouterRouting = $LogicalRouterRouting.CloneNode($true)

        #Store the logicalrouterId and remove it from the XML as we need to post it...
        $logicalrouterId = $_LogicalRouterRouting.logicalrouterId
        $_LogicalRouterRouting.RemoveChild( $($_LogicalRouterRouting.SelectSingleNode('child::logicalrouterId')) ) | out-null

        #Need to do an xpath query here rather than use PoSH dot notation to get the protocol element,
        #as it might not exist which wil cause PoSH to throw in stric mode.
        $ProtocolElement = $_LogicalRouterRouting.SelectSingleNode("child::$Learner")

        if ( (-not $ProtocolElement) -or ($ProtocolElement.Enabled -ne 'true')) { 

            throw "The $Learner protocol is not enabled on LogicalRouter $logicalrouterId.  Enable it and try again."
        }
        else {
        
            #Create the new rule element. 
            $Rule = $_LogicalRouterRouting.ownerDocument.CreateElement('rule')
            $ProtocolElement.selectSingleNode('child::redistribution/rules').AppendChild($Rule) | Out-Null

            Add-XmlElement -xmlRoot $Rule -xmlElementName "action" -xmlElementText $Action
            if ( $PsBoundParameters.ContainsKey("PrefixName") ) { 
                Add-XmlElement -xmlRoot $Rule -xmlElementName "prefixName" -xmlElementText $PrefixName.ToString()
            }


            #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
            #If the user did not specify a given parameter, we dont want to modify from the existing value.
            if ( $PsBoundParameters.ContainsKey('FromConnected') -or $PsBoundParameters.ContainsKey('FromStatic') -or
                 $PsBoundParameters.ContainsKey('FromOspf') -or $PsBoundParameters.ContainsKey('FromBgp') ) {

                $FromElement = $Rule.ownerDocument.CreateElement('from')
                $Rule.AppendChild($FromElement) | Out-Null

                if ( $PsBoundParameters.ContainsKey("FromConnected") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "connected" -xmlElementText $FromConnected.ToString().ToLower()
                }

                if ( $PsBoundParameters.ContainsKey("FromStatic") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "static" -xmlElementText $FromStatic.ToString().ToLower()
                }
    
                if ( $PsBoundParameters.ContainsKey("FromOspf") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "ospf" -xmlElementText $FromOspf.ToString().ToLower()
                }

                if ( $PsBoundParameters.ContainsKey("FromBgp") ) { 
                    Add-XmlElement -xmlRoot $FromElement -xmlElementName "bgp" -xmlElementText $FromBgp.ToString().ToLower()
                }
            }

            $URI = "/api/4.0/edges/$($LogicalRouterId)/routing/config"
            $body = $_LogicalRouterRouting.OuterXml 
           
            
            if ( $confirm ) { 
                $message  = "LogicalRouter routing update will modify existing LogicalRouter configuration."
                $question = "Proceed with Update of LogicalRouter $($LogicalRouterId)?"
                $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
                $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

                $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
            }    
            else { $decision = 0 } 
            if ($decision -eq 0) {
                Write-Progress -activity "Update LogicalRouter $($LogicalRouterId)"
                $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
                write-progress -activity "Update LogicalRouter $($LogicalRouterId)" -completed
                (Get-NsxLogicalRouter -objectId $LogicalRouterId | Get-NsxLogicalRouterRouting | Get-NsxLogicalRouterRedistributionRule -Learner $Learner)[-1]
                
            }
        }
    }

    end {}
}
Export-ModuleMember -Function New-NsxLogicalRouterRedistributionRule

#########
#########
# Grouping related Collections

function Get-NsxSecurityGroup {

    <#
    .SYNOPSIS
    Retrieves NSX Security Groups

    .DESCRIPTION
    An NSX Security Group is a grouping construct that provides a powerful
    grouping function that can be used in DFW Firewall Rules and the NSX
    Service Composer.

    This cmdlet returns Security Groups objects.

    .EXAMPLE
    PS C:\> Get-NsxSecurityGroup TestSG

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$false,ParameterSetName="objectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$name,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"

    )
    
    begin {

    }

    process {
     
        if ( -not $objectId ) { 
            #All Security GRoups
            $URI = "/api/2.0/services/securitygroup/scope/$scopeId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if  ( $Name  ) { 
                $response.list.securitygroup | ? { $_.name -eq $name }
            } else {
                $response.list.securitygroup
            }

        }
        else {

            #Just getting a single Security group
            $URI = "/api/2.0/services/securitygroup/$objectId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $response.securitygroup 
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxSecurityGroup

function New-NsxSecurityGroup   {

    <#
    .SYNOPSIS
    Creates a new NSX Security Group.

    .DESCRIPTION
    An NSX Security Group is a grouping construct that provides a powerful
    grouping function that can be used in DFW Firewall Rules and the NSX
    Service Composer.

    This cmdlet creates a new NSX Security Group.

    A Security Group can consist of Static Includes and Excludes as well as 
    dynamic matching properties.  At this time, this cmdlet supports only static 
    include/exclude members.

    A valid PowerCLI session is required to pass certain types of objects 
    supported by the IncludeMember and ExcludeMember parameters.
    

    .EXAMPLE

    Example1: Create a new SG and include App01 and App02 VMs (get-vm requires a
    valid PowerCLI session)

    PS C:\> New-NsxSecurityGroup -Name TestSG -Description "Test creating an NSX
     SecurityGroup" -IncludeMember (get-vm app01),(get-vm app02)

    Example2: Create a new SG and include cluster1 except for App01 and App02 
    VMs (get-vm and get-cluster requires a valid PowerCLI session)

    PS C:\> New-NsxSecurityGroup -Name TestSG -Description "Test creating an NSX
     SecurityGroup" -IncludeMember (get-cluster cluster1) 
        -ExcludeMember (get-vm app01),(get-vm app02)
    #>

    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$Description = "",
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-SecurityGroupMember $_ })]
            [object[]]$IncludeMember,
            [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-SecurityGroupMember $_ })]
            [object[]]$ExcludeMember,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"
    )

    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("securitygroup")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "description" -xmlElementText $Description
        if ( $includeMember ) { 
        
            foreach ( $Member in $IncludeMember) { 

                [System.XML.XMLElement]$xmlMember = $XMLDoc.CreateElement("member")
                $xmlroot.appendChild($xmlMember) | out-null

                #This is probably not safe - need to review all possible input types to confirm.
                if ($Member -is [System.Xml.XmlElement] ) {
                    Add-XmlElement -xmlRoot $xmlMember -xmlElementName "objectId" -xmlElementText $member.objectId
                } else { 
                    Add-XmlElement -xmlRoot $xmlMember -xmlElementName "objectId" -xmlElementText $member.ExtensionData.MoRef.Value
                }
            }
        }   

        if ( $excludeMember ) { 
        
            foreach ( $Member in $ExcludeMember) { 

                [System.XML.XMLElement]$xmlMember = $XMLDoc.CreateElement("excludeMember")
                $xmlroot.appendChild($xmlMember) | out-null

                #This is probably not safe - need to review all possible input types to confirm.
                if ($Member -is [System.Xml.XmlElement] ) {
                    Add-XmlElement -xmlRoot $xmlMember -xmlElementName "objectId" -xmlElementText $member.objectId
                } else { 
                    Add-XmlElement -xmlRoot $xmlMember -xmlElementName "objectId" -xmlElementText $member.ExtensionData.MoRef.Value
                }
            }
        }   

        #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/2.0/services/securitygroup/bulk/$scopeId"
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body

        Get-NsxSecuritygroup -objectId $response
    }
    end {}
}
Export-ModuleMember -Function New-NsxSecurityGroup

function Remove-NsxSecurityGroup {

    <#
    .SYNOPSIS
    Removes the specified NSX Security Group.

    .DESCRIPTION
    An NSX Security Group is a grouping construct that provides a powerful
    grouping function that can be used in DFW Firewall Rules and the NSX
    Service Composer.

    This cmdlet deletes a specified Security Groups object.  If the object 
    is currently in use the api will return an error.  Use -force to override
    but be aware that the firewall rulebase will become invalid and will need
    to be corrected before publish operations will succeed again.

    .EXAMPLE
    Example1: Remove the SecurityGroup TestSG
    PS C:\> Get-NsxSecurityGroup TestSG | Remove-NsxSecurityGroup

    Example2: Remove the SecurityGroup $sg without confirmation.
    PS C:\> $sg | Remove-NsxSecurityGroup -confirm:$false

    
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$SecurityGroup,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false


    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Security Group removal is permanent."
            $question = "Proceed with removal of Security group $($SecurityGroup.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            if ( $force ) { 
                $URI = "/api/2.0/services/securitygroup/$($SecurityGroup.objectId)?force=true"
            }
            else {
                $URI = "/api/2.0/services/securitygroup/$($SecurityGroup.ObjectId)?force=false"
            }
            
            Write-Progress -activity "Remove Security Group $($SecurityGroup.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove Security Group $($SecurityGroup.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxSecurityGroup

function Get-NsxIPSet {

    <#
    .SYNOPSIS
    Retrieves NSX IPSets

    .DESCRIPTION
    An NSX IPSet is a grouping construct that allows for grouping of
    IP adresses, ranges and/or subnets in a sigle container that can 
    be used either in DFW Firewall Rules or as members of a security 
    group.

    This cmdlet returns IP Set objects.

    .EXAMPLE
    PS C:\> Get-NSXIpSet TestIPSet

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$false,ParameterSetName="objectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"

    )
    
    begin {

    }

    process {
     
        if ( -not $objectID ) { 
            #All IPSets
            $URI = "/api/2.0/services/ipset/scope/$scopeId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if ( $name ) {
                $response.list.ipset | ? { $_.name -eq $name }
            } else {
                $response.list.ipset
            }
        }
        else {

            #Just getting a single named Security group
            $URI = "/api/2.0/services/ipset/$objectId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $response.ipset
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxIPSet

function New-NsxIPSet  {
    <#
    .SYNOPSIS
    Creates a new NSX IPSet.

    .DESCRIPTION
    An NSX IPSet is a grouping construct that allows for grouping of
    IP adresses, ranges and/or subnets in a sigle container that can 
    be used either in DFW Firewall Rules or as members of a security 
    group.

    This cmdlet creates a new IP Set with the specified parameters.

    IPAddresses is a string that can contain 1 or more of the following
    separated by commas
    IP address: (eg, 1.2.3.4)
    IP Range: (eg, 1.2.3.4-1.2.3.10)
    IP Subnet (eg, 1.2.3.0/24)


    .EXAMPLE
    PS C:\> New-NsxIPSet -Name TestIPSet -Description "Testing IP Set Creation" 
        -IPAddresses "1.2.3.4,1.2.3.0/24"

    #>

    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$Description = "",
        [Parameter (Mandatory=$false)]
            [string]$IPAddresses,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"
    )

    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("ipset")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "description" -xmlElementText $Description
        if ( $IPAddresses ) {
            Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "value" -xmlElementText $IPaddresses
        }
           
        #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/2.0/services/ipset/$scopeId"
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body

        Get-NsxIPSet -objectid $response
    }
    end {}
}
Export-ModuleMember -Function New-NsxIPSet

function Remove-NsxIPSet {

    <#
    .SYNOPSIS
    Removes the specified NSX IPSet.

    .DESCRIPTION
    An NSX IPSet is a grouping construct that allows for grouping of
    IP adresses, ranges and/or subnets in a sigle container that can 
    be used either in DFW Firewall Rules or as members of a security 
    group.

    This cmdlet removes the specified IP Set. If the object 
    is currently in use the api will return an error.  Use -force to override
    but be aware that the firewall rulebase will become invalid and will need
    to be corrected before publish operations will succeed again.

    .EXAMPLE
    PS C:\> Get-NsxIPSet TestIPSet | Remove-NsxIPSet

    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$IPSet,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false


    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "IPSet removal is permanent."
            $question = "Proceed with removal of IP Set $($IPSet.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            if ( $force ) { 
                $URI = "/api/2.0/services/ipset/$($IPSet.objectId)?force=true"
            }
            else {
                $URI = "/api/2.0/services/ipset/$($IPSet.objectId)?force=false"
            }
            
            Write-Progress -activity "Remove IP Set $($IPSet.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove IP Set $($IPSet.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxIPSet

function Get-NsxMacSet {

    <#
    .SYNOPSIS
    Retrieves NSX MACSets

    .DESCRIPTION
    An NSX MACSet is a grouping construct that allows for grouping of
    MAC Addresses in a sigle container that can 
    be used either in DFW Firewall Rules or as members of a security 
    group.

    This cmdlet returns MAC Set objects.

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$false,ParameterSetName="objectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"

    )
    
    begin {

    }

    process {
     
        if ( -not $objectID ) { 
            #All IPSets
            $URI = "/api/2.0/services/macset/scope/$scopeId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if ( $name ) {
                $response.list.macset | ? { $_.name -eq $name }
            } else {
                $response.list.macset
            }
        }
        else {

            #Just getting a single named MACset
            $URI = "/api/2.0/services/macset/$objectId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $response.macset
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxMACSet

function New-NsxMacSet  {
    <#
    .SYNOPSIS
    Creates a new NSX MACSet.

    .DESCRIPTION
    An NSX MACSet is a grouping construct that allows for grouping of
    MAC Addresses in a sigle container that can 
    be used either in DFW Firewall Rules or as members of a security 
    group.

    This cmdlet creates a new MAC Set with the specified parameters.

    MacAddresses is a string that can contain 1 or more MAC Addresses the following
    separated by commas
    Mac address: (eg, 00:00:00:00:00:00)
    

    #>

    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$Description = "",
        [Parameter (Mandatory=$false)]
            [string]$MacAddresses,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"
    )

    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("macset")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "description" -xmlElementText $Description
        if ( $MacAddresses ) {
            Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "value" -xmlElementText $MacAddresses
        }
           
        #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/2.0/services/macset/$scopeId"
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body

        Get-NsxMacSet -objectid $response
    }
    end {}
}
Export-ModuleMember -Function New-NsxMacSet

function Remove-NsxMacSet {

    <#
    .SYNOPSIS
    Removes the specified NSX MacSet.

    .DESCRIPTION
    An NSX MacSet is a grouping construct that allows for grouping of
    Mac Addresses in a sigle container that can 
    be used either in DFW Firewall Rules or as members of a security 
    group.

    This cmdlet removes the specified MAC Set. If the object 
    is currently in use the api will return an error.  Use -force to override
    but be aware that the firewall rulebase will become invalid and will need
    to be corrected before publish operations will succeed again.


    #>
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$MacSet,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false

    )
    
    begin {
    }

    process {

        if ( $confirm ) { 
            $message  = "MACSet removal is permanent."
            $question = "Proceed with removal of MAC Set $($MACSet.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            if ( $force ) { 
                $URI = "/api/2.0/services/macset/$($MACSet.objectId)?force=true"
            }
            else {
                $URI = "/api/2.0/services/macset/$($MACSet.objectId)?force=false"
            }
            
            Write-Progress -activity "Remove MAC Set $($MACSet.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove MAC Set $($MACSet.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxMacSet

function Get-NsxService {

    <#
    .SYNOPSIS
    Retrieves NSX Services (aka Applications).

    .DESCRIPTION
    An NSX Service defines a service as configured in the NSX Distributed
    Firewall.  

    This cmdlet retrieves existing services as defined within NSX.

    It also supports searching for services by TCP/UDP port number and will
    locate services that contain the specified port within a range definition
    as well as those explicitly configured with the given port.

    .EXAMPLE
    Example1: Get Service by name
    PS C:\> Get-NsxService -Name TestService 

    Example2: Get Service by port (will match services that include the 
    specified port within a range as well as those explicitly configured with 
    the given port.)
    PS C:\> Get-NsxService -port 1234

    #>    
    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$false,ParameterSetName="objectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$false,ParameterSetName="Port",Position=1)]
            [int]$Port,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"

    )
    
    begin {

    }

    process {

        switch ( $PSCmdlet.ParameterSetName ) {

            "objectId" {

                  #Just getting a single named service group
                $URI = "/api/2.0/services/application/$objectId"
                $response = invoke-nsxrestmethod -method "get" -uri $URI
                $response.application
            }

            "Name" { 
                #All Services
                $URI = "/api/2.0/services/application/scope/$scopeId"
                $response = invoke-nsxrestmethod -method "get" -uri $URI
                if  ( $name ) { 
                    $response.list.application | ? { $_.name -eq $name }
                } else {
                    $response.list.application
                }
            }

            "Port" {

                # Service by port

                $URI = "/api/2.0/services/application/scope/$scopeId"
                $response = invoke-nsxrestmethod -method "get" -uri $URI
                foreach ( $application in $response.list.application ) {

                    if ( $application | get-member -memberType Properties -name element ) {
                        write-debug "$($MyInvocation.MyCommand.Name) : Testing service $($application.name) with ports: $($application.element.value)"

                        #The port configured on a service is stored in element.value and can be
                        #either an int, range (expressed as inta-intb, or a comma separated list of ints and/or ranges
                        #So we split the value on comma, the replace the - with .. in a range, and wrap parentheses arount it
                        #Then, lean on PoSH native range handling to force the lot into an int array... 
                        
                        switch -regex ( $application.element.value ) {

                            "^[\d,-]+$" { 

                                [string[]]$valarray = $application.element.value.split(",") 
                                foreach ($val in $valarray)  { 

                                    write-debug "$($MyInvocation.MyCommand.Name) : Converting range expression and expanding: $val"  
                                    [int[]]$ports = invoke-expression ( $val -replace '^(\d+)-(\d+)$','($1..$2)' ) 
                                    #Then test if the port int array contains what we are looking for...
                                    if ( $ports.contains($port) ) { 
                                        write-debug "$($MyInvocation.MyCommand.Name) : Matched Service $($Application.name)"
                                        $application
                                        break
                                    }
                                }
                            }

                            default { #do nothing, port number is not numeric.... 
                                write-debug "$($MyInvocation.MyCommand.Name) : Ignoring $($application.name) - non numeric element: $($application.element.applicationProtocol) : $($application.element.value)"
                            }
                        }
                    }
                    else {
                        write-debug "$($MyInvocation.MyCommand.Name) : Ignoring $($application.name) - element not defined"                           
                    }
                }
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxService

function New-NsxService  {

    <#
    .SYNOPSIS
    Creates a new NSX Service (aka Application).

    .DESCRIPTION
    An NSX Service defines a service as configured in the NSX Distributed
    Firewall.  

    This cmdlet creates a new service of the specified configuration.

    .EXAMPLE
    PS C:\> New-NsxService -Name TestService -Description "Test creation of a 
     service" -Protocol TCP -port 1234

    #>    

    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [string]$Description = "",
        [Parameter (Mandatory=$true)]
            [ValidateSet ("TCP","UDP",
            "ORACLE_TNS","FTP","SUN_RPC_TCP",
            "SUN_RPC_UDP","MS_RPC_TCP",
            "MS_RPC_UDP","NBNS_BROADCAST",
            "NBDG_BROADCAST")]
            [string]$Protocol,
        [Parameter (Mandatory=$true)]
            [ValidateScript({
                if ( ($Protocol -eq "TCP" ) -or ( $protocol -eq "UDP")) { 
                    if ( $_ -match "^[\d,-]+$" ) { $true } else { throw "TCP or UDP port numbers must be either an integer, range (nn-nn) or commma separated integers or ranges." }
                } else {
                    #test we can cast to int
                    if ( ($_ -as [int]) -and ( (1..65535) -contains $_) ) { 
                        $true 
                    } else { 
                        throw "Non TCP or UDP port numbers must be a single integer between 1-65535."
                    }
                }
            })]
            [string]$port,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"
    )

    begin {}
    process { 

        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("application")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "description" -xmlElementText $Description
        
        #Create the 'element' element ??? :)
        [System.XML.XMLElement]$xmlElement = $XMLDoc.CreateElement("element")
        $xmlRoot.appendChild($xmlElement) | out-null
        
        Add-XmlElement -xmlRoot $xmlElement -xmlElementName "applicationProtocol" -xmlElementText $Protocol
        Add-XmlElement -xmlRoot $xmlElement -xmlElementName "value" -xmlElementText $Port
           
        #Do the post
        $body = $xmlroot.OuterXml
        $URI = "/api/2.0/services/application/$scopeId"
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body

        Get-NsxService -objectId $response
    }
    end {}
}
Export-ModuleMember -Function New-NsxService

function Remove-NsxService {

    <#
    .SYNOPSIS
    Removes the specified NSX Service (aka Application).

    .DESCRIPTION
    An NSX Service defines a service as configured in the NSX Distributed
    Firewall.  

    This cmdlet removes the NSX service specified.

    .EXAMPLE
    PS C:\> New-NsxService -Name TestService -Description "Test creation of a
     service" -Protocol TCP -port 1234

    #>    
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$Service,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false
    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Service removal is permanent."
            $question = "Proceed with removal of Service $($Service.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            if ( $force ) { 
                $URI = "/api/2.0/services/application/$($Service.objectId)?force=true"
            }
            else {
                $URI = "/api/2.0/services/application/$($Service.objectId)?force=false"
            }
            
            Write-Progress -activity "Remove Service $($Service.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove Service $($Service.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxService

#########
#########
# Firewall related functions

###Private functions

function New-NsxSourceDestNode {

    #Internal function - Handles building the source/dest xml node for a given object.

    param (

        [Parameter (Mandatory=$true)]
        [ValidateSet ("source","destination")]
        [string]$itemType,
        [object[]]$itemlist,
        [System.XML.XMLDocument]$xmlDoc,
        [switch]$negateItem

    )

    #The excluded attribute indicates source/dest negation
    $xmlAttrNegated = $xmlDoc.createAttribute("excluded")
    if ( $negateItem ) { 
        $xmlAttrNegated.value = "true"
    } else { 
        $xmlAttrNegated.value = "false"
    }

    #Create return element and append negation attribute.
    if ( $itemType -eq "Source" ) { [System.XML.XMLElement]$xmlReturn = $XMLDoc.CreateElement("sources") }
    if ( $itemType -eq "Destination" ) { [System.XML.XMLElement]$xmlReturn = $XMLDoc.CreateElement("destinations") }
    $xmlReturn.Attributes.Append($xmlAttrNegated) | out-null

    foreach ($item in $itemlist) {
        write-debug "$($MyInvocation.MyCommand.Name) : Building source/dest node for $($item.name)"
        #Build the return XML element
        [System.XML.XMLElement]$xmlItem = $XMLDoc.CreateElement($itemType)

        if ( $item -is [system.xml.xmlelement] ) {

            write-debug "$($MyInvocation.MyCommand.Name) : Object $($item.name) is specified as xml element"
            #XML representation of NSX object passed - ipset, sec group or logical switch
            #get appropritate name, value.
            Add-XmlElement -xmlRoot $xmlItem -xmlElementName "value" -xmlElementText $item.objectId
            Add-XmlElement -xmlRoot $xmlItem -xmlElementName "name" -xmlElementText $item.name
            Add-XmlElement -xmlRoot $xmlItem -xmlElementName "type" -xmlElementText $item.objectTypeName
            
        } else {

            write-debug "$($MyInvocation.MyCommand.Name) : Object $($item.name) is specified as supported powercli object"
            #Proper PowerCLI Object passed
            #If passed object is a NIC, we have to do some more digging
            if (  $item -is [VMware.VimAutomation.ViCore.Types.V1.VirtualDevice.NetworkAdapter] ) {
                   
                write-debug "$($MyInvocation.MyCommand.Name) : Object $($item.name) is vNic"
                #Naming based on DFW UI standard
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "name" -xmlElementText "$($item.parent.name) - $($item.name)"
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "type" -xmlElementText "Vnic"

                #Getting the NIC identifier is a bit of hackery at the moment, if anyone can show me a more deterministic or simpler way, then im all ears. 
                $nicIndex = [array]::indexof($item.parent.NetworkAdapters.name,$item.name)
                if ( -not ($nicIndex -eq -1 )) { 
                    Add-XmlElement -xmlRoot $xmlItem -xmlElementName "value" -xmlElementText "$($item.parent.PersistentId).00$nicINdex"
                } else {
                    throw "Unable to determine nic index in parent object.  Make sure the NIC object is valid"
                }
            }
            else {
                #any other accepted PowerCLI object, we just need to grab details from the moref.
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "name" -xmlElementText $item.name
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "type" -xmlElementText $item.extensiondata.moref.type
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "value" -xmlElementText $item.extensiondata.moref.value 
            }
        }

        
        $xmlReturn.appendChild($xmlItem) | out-null
    }

    $xmlReturn
}

function New-NsxAppliedToListNode {

    #Internal function - Handles building the apliedto xml node for a given object.

    param (

        [object[]]$itemlist,
        [System.XML.XMLDocument]$xmlDoc,
        [switch]$ApplyToDFW

    )


    [System.XML.XMLElement]$xmlReturn = $XMLDoc.CreateElement("appliedToList")
    #Iterate the appliedTo passed and build appliedTo nodes.
    #$xmlRoot.appendChild($xmlReturn) | out-null

    if ( $ApplyToDFW ) {

        [System.XML.XMLElement]$xmlAppliedTo = $XMLDoc.CreateElement("appliedTo")
        $xmlReturn.appendChild($xmlAppliedTo) | out-null
        Add-XmlElement -xmlRoot $xmlAppliedTo -xmlElementName "name" -xmlElementText "DISTRIBUTED_FIREWALL"
        Add-XmlElement -xmlRoot $xmlAppliedTo -xmlElementName "type" -xmlElementText "DISTRIBUTED_FIREWALL"
        Add-XmlElement -xmlRoot $xmlAppliedTo -xmlElementName "value" -xmlElementText "DISTRIBUTED_FIREWALL"

    } else {


        foreach ($item in $itemlist) {
            write-debug "$($MyInvocation.MyCommand.Name) : Building appliedTo node for $($item.name)"
            #Build the return XML element
            [System.XML.XMLElement]$xmlItem = $XMLDoc.CreateElement("appliedTo")

            if ( $item -is [system.xml.xmlelement] ) {

                write-debug "$($MyInvocation.MyCommand.Name) : Object $($item.name) is specified as xml element"
                #XML representation of NSX object passed - ipset, sec group or logical switch
                #get appropritate name, value.
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "value" -xmlElementText $item.objectId
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "name" -xmlElementText $item.name
                Add-XmlElement -xmlRoot $xmlItem -xmlElementName "type" -xmlElementText $item.objectTypeName
                  
            } else {

                write-debug "$($MyInvocation.MyCommand.Name) : Object $($item.name) is specified as supported powercli object"
                #Proper PowerCLI Object passed
                #If passed object is a NIC, we have to do some more digging
                if (  $item -is [VMware.VimAutomation.ViCore.Types.V1.VirtualDevice.NetworkAdapter] ) {
                   
                    write-debug "$($MyInvocation.MyCommand.Name) : Object $($item.name) is vNic"
                    #Naming based on DFW UI standard
                    Add-XmlElement -xmlRoot $xmlItem -xmlElementName "name" -xmlElementText "$($item.parent.name) - $($item.name)"
                    Add-XmlElement -xmlRoot $xmlItem -xmlElementName "type" -xmlElementText "Vnic"

                    #Getting the NIC identifier is a bit of hackery at the moment, if anyone can show me a more deterministic or simpler way, then im all ears. 
                    $nicIndex = [array]::indexof($item.parent.NetworkAdapters.name,$item.name)
                    if ( -not ($nicIndex -eq -1 )) { 
                        Add-XmlElement -xmlRoot $xmlItem -xmlElementName "value" -xmlElementText "$($item.parent.PersistentId).00$nicINdex"
                    } else {
                        throw "Unable to determine nic index in parent object.  Make sure the NIC object is valid"
                    }
                }
                else {
                    #any other accepted PowerCLI object, we just need to grab details from the moref.
                    Add-XmlElement -xmlRoot $xmlItem -xmlElementName "name" -xmlElementText $item.name
                    Add-XmlElement -xmlRoot $xmlItem -xmlElementName "type" -xmlElementText $item.extensiondata.moref.type
                    Add-XmlElement -xmlRoot $xmlItem -xmlElementName "value" -xmlElementText $item.extensiondata.moref.value 
                }
            }

        
            $xmlReturn.appendChild($xmlItem) | out-null
        }
    }
    $xmlReturn
}

###End Private Functions

function Get-NsxFirewallSection {
   
    <#
    .SYNOPSIS
    Retrieves the specified NSX Distributed Firewall Section.

    .DESCRIPTION
    An NSX Distributed Firewall Section is a named portion of the firewall rule set that contains
    firewall rules.  

    This cmdlet retrieves the specified NSX Distributed Firewall Section.

    .EXAMPLE
    PS C:\> Get-NsxFirewallSection TestSection

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$false,ParameterSetName="ObjectId")]
            [string]$objectId,
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0",
        [Parameter (Mandatory=$false,Position=1,ParameterSetName="Name")]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateSet("layer3sections","layer2sections","layer3redirectsections",ignorecase=$false)]
            [string]$sectionType="layer3sections"

    )
    
    begin {

    }

    process {
     
        if ( -not $objectID ) { 
            #All Sections

            $URI = "/api/4.0/firewall/$scopeID/config"
            $response = invoke-nsxrestmethod -method "get" -uri $URI

            $return = $response.firewallConfiguration.$sectiontype.section

            if ($name) {
                $return | ? {$_.name -eq $name} 
            }else {
            
                $return
            }

        }
        else {
            
            $URI = "/api/4.0/firewall/$scopeID/config/$sectionType/$objectId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $response.section
        }

    }

    end {}
}
Export-ModuleMember -Function Get-NsxFirewallSection

function New-NsxFirewallSection  {


    <#
    .SYNOPSIS
    Creates a new NSX Distributed Firewall Section.

    .DESCRIPTION
    An NSX Distributed Firewall Section is a named portion of the firewall rule 
    set that contains firewall rules.  

    This cmdlet create the specified NSX Distributed Firewall Section.  
    Currently this cmdlet only supports creating a section at the top of the 
    ruleset.

    .EXAMPLE
    PS C:\> New-NsxFirewallSection -Name TestSection

    #>

    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [ValidateSet("layer3sections","layer2sections","layer3redirectsections",ignorecase=$false)]
            [string]$sectionType="layer3sections",
        [Parameter (Mandatory=$false)]
            [string]$scopeId="globalroot-0"
    )

    begin {}
    process { 


        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRoot = $XMLDoc.CreateElement("section")
        $xmlDoc.appendChild($xmlRoot) | out-null

        Add-XmlElement -xmlRoot $xmlRoot -xmlElementName "name" -xmlElementText $Name
           
        #Do the post
        $body = $xmlroot.OuterXml
        
        $URI = "/api/4.0/firewall/$scopeId/config/$sectionType"
        
        $response = invoke-nsxrestmethod -method "post" -uri $URI -body $body

        $response.section
        
    }
    end {}
}
Export-ModuleMember -Function New-NsxFirewallSection

function Remove-NsxFirewallSection {

    
    <#
    .SYNOPSIS
    Removes the specified NSX Distributed Firewall Section.

    .DESCRIPTION
    An NSX Distributed Firewall Section is a named portion of the firewall rule 
    set that contains firewall rules.  

    This cmdlet removes the specified NSX Distributed Firewall Section.  If the 
    section contains rules, the removal attempt fails.  Specify -force to 
    override this, but be aware that all firewall rules contained within the 
    section are removed along with it.

    .EXAMPLE
    PS C:\> New-NsxFirewallSection -Name TestSection

    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNull()]
            [System.Xml.XmlElement]$Section,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false
    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Firewall Section removal is permanent and cannot be reversed."
            $question = "Proceed with removal of Section $($Section.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            if ( $Section.Name -match 'Default Section' ) {
                write-warning "Will not delete $($Section.Name)."
            }
                else { 
                if ( $force ) { 
                    $URI = "/api/4.0/firewall/globalroot-0/config/$($Section.ParentNode.name.tolower())/$($Section.Id)"
                }
                else {
                    
                    if ( $section |  get-member -MemberType Properties -Name rule ) { throw "Section $($section.name) contains rules.  Specify -force to delete this section" }
                    else {
                        $URI = "/api/4.0/firewall/globalroot-0/config/$($Section.ParentNode.name.tolower())/$($Section.Id)"
                    }
                }
                
                Write-Progress -activity "Remove Section $($Section.Name)"
                invoke-nsxrestmethod -method "delete" -uri $URI | out-null
                write-progress -activity "Remove Section $($Section.Name)" -completed
            }
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxFirewallSection 

function Get-NsxFirewallRule {

    <#
    .SYNOPSIS
    Retrieves the specified NSX Distributed Firewall Rule.

    .DESCRIPTION
    An NSX Distributed Firewall Rule defines a typical 5 tuple rule and is 
    enforced on each hypervisor at the point where the VMs NIC connects to the 
    portgroup or logical switch.  

    Additionally, the 'applied to' field allow additional flexibility about 
    where (as in VMs, networks, hosts etc) the rule is actually applied.

    This cmdlet retrieves the specified NSX Distributed Firewall Rule.  It is
    also effective used in conjunction with an NSX firewall section as 
    returned by Get-NsxFirewallSection being passed on the pipeline to retrieve
    all the rules defined within the given section.

    .EXAMPLE
    PS C:\> Get-NsxFirewallSection TestSection | Get-NsxFirewallRule

    #>


    [CmdletBinding(DefaultParameterSetName="Section")]

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,ParameterSetName="Section")]
        [ValidateNotNull()]
            [System.Xml.XmlElement]$Section,
        [Parameter (Mandatory=$false, Position=1)]
            [ValidateNotNullorEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true,ParameterSetName="RuleId")]
        [ValidateNotNullOrEmpty()]
            [string]$RuleId,
        [Parameter (Mandatory=$false)]
            [string]$ScopeId="globalroot-0",
        [Parameter (Mandatory=$false)]
            [ValidateSet("layer3sections","layer2sections","layer3redirectsections",ignorecase=$false)]
            [string]$RuleType="layer3sections"

    )
    
    begin {

    }

    process {
     
        if ( $PSCmdlet.ParameterSetName -eq "Section" ) { 

            $URI = "/api/4.0/firewall/$scopeID/config/$ruletype/$($Section.Id)"
            
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if ( $response | get-member -name Section -Membertype Properties){
                if ( $response.Section | get-member -name Rule -Membertype Properties ){
                    if ( $PsBoundParameters.ContainsKey("Name") ) { 
                        $response.section.rule | ? { $_.name -eq $Name }
                    }
                    else {
                        $response.section.rule
                    }
                }
            }
        }
        else { 

            #SpecificRule - returned xml is firewallconfig -> layer3sections -> section.  
            #In our infinite wisdom, we use a different string here for the section type :|  
            #Kinda considering searching each section type here and returning result regardless of section
            #type if user specifies ruleid...   The I dont have to make the user specify the ruletype...
            switch ($ruleType) {

                "layer3sections" { $URI = "/api/4.0/firewall/$scopeID/config?ruleType=LAYER3&ruleId=$RuleId" }
                "layer2sections" { $URI = "/api/4.0/firewall/$scopeID/config?ruleType=LAYER2&ruleId=$RuleId" }
                "layer3redirectsections" { $URI = "/api/4.0/firewall/$scopeID/config?ruleType=L3REDIRECT&ruleId=$RuleId" }
                default { throw "Invalid rule type" }
            }

            #NSX 6.2 introduced a change in the API wheras the element returned
            #for a query such as we are doing here is now called 
            #'filteredfirewallConfiguration'.  Why? :|

            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if ($response.firewallConfiguration) { 
                if ( $PsBoundParameters.ContainsKey("Name") ) { 
                    $response.firewallConfiguration.layer3Sections.Section.rule | ? { $_.name -eq $Name }
                }
                else {
                    $response.firewallConfiguration.layer3Sections.Section.rule
                }

            } 
            elseif ( $response.filteredfirewallConfiguration ) { 
                if ( $PsBoundParameters.ContainsKey("Name") ) { 
                    $response.filteredfirewallConfiguration.layer3Sections.Section.rule | ? { $_.name -eq $Name }
                }
                else {
                    $response.filteredfirewallConfiguration.layer3Sections.Section.rule
                }
            }
            else { throw "Invalid response from NSX API. $response"}
        }
    }

    end {}
}
Export-ModuleMember -Function Get-NsxFirewallRule

function New-NsxFirewallRule  {

    <#
    .SYNOPSIS
    Creates a new NSX Distributed Firewall Rule.

    .DESCRIPTION
    An NSX Distributed Firewall Rule defines a typical 5 tuple rule and is 
    enforced on each hypervisor at the point where the VMs NIC connects to the 
    portgroup or logical switch.  

    Additionally, the 'applied to' field allows flexibility about 
    where (as in VMs, networks, hosts etc) the rule is actually applied.

    This cmdlet creates the specified NSX Distributed Firewall Rule. The section
    in which to create the rule is mandatory. 

    .EXAMPLE
    PS C:\> Get-NsxFirewallSection TestSection | 
        New-NsxFirewallRule -Name TestRule -Source $LS1 -Destination $LS1 
        -Action allow
        -service (Get-NsxService HTTP) -AppliedTo $LS1 -EnableLogging -Comment 
         "Testing Rule Creation"

    #>

    [CmdletBinding()]
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,ParameterSetName="Section")]
            [ValidateNotNull()]
            [System.Xml.XmlElement]$Section,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateSet("allow","deny","reject")]
            [string]$Action,
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-FirewallRuleSourceDest $_ })]
            [object[]]$Source,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$NegateSource,
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-FirewallRuleSourceDest $_ })]
            [object[]]$Destination,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [switch]$NegateDestination,
        [Parameter (Mandatory=$false)]
            [ValidateScript ({ Validate-Service $_ })]
            [System.Xml.XmlElement[]]$Service,
        [Parameter (Mandatory=$false)]
            [string]$Comment="",
        [Parameter (Mandatory=$false)]
            [switch]$EnableLogging,  
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-FirewallAppliedTo $_ })]
            [object[]]$AppliedTo,
        [Parameter (Mandatory=$false)]
            [ValidateSet("layer3sections","layer2sections","layer3redirectsections",ignorecase=$false)]
            [string]$RuleType="layer3sections",
        [Parameter (Mandatory=$false)]
            [ValidateSet("Top","Bottom")]
            [string]$Position="Top",    
        [Parameter (Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [string]$Tag,
        [Parameter (Mandatory=$false)]
            [string]$ScopeId="globalroot-0"
    )

    begin {}
    process { 

        
        $generationNumber = $section.generationNumber           

        write-debug "$($MyInvocation.MyCommand.Name) : Preparing rule for section $($section.Name) with generationId $generationNumber"
        #Create the XMLRoot
        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlRule = $XMLDoc.CreateElement("rule")
        $xmlDoc.appendChild($xmlRule) | out-null

        Add-XmlElement -xmlRoot $xmlRule -xmlElementName "name" -xmlElementText $Name
        #Add-XmlElement -xmlRoot $xmlRule -xmlElementName "sectionId" -xmlElementText $($section.Id)
        Add-XmlElement -xmlRoot $xmlRule -xmlElementName "notes" -xmlElementText $Comment
        Add-XmlElement -xmlRoot $xmlRule -xmlElementName "action" -xmlElementText $action
        if ( $EnableLogging ) {
            #Enable Logging attribute
            $xmlAttrLog = $xmlDoc.createAttribute("logged")
            $xmlAttrLog.value = "true"
            $xmlRule.Attributes.Append($xmlAttrLog) | out-null
            
        }
                    
        #Build Sources Node
        if ( $source ) {
            $xmlSources = New-NsxSourceDestNode -itemType "source" -itemlist $source -xmlDoc $xmlDoc -negateItem:$negateSource
            $xmlRule.appendChild($xmlSources) | out-null
        }

        #Destinations Node
        if ( $destination ) { 
            $xmlDestinations = New-NsxSourceDestNode -itemType "destination" -itemlist $destination -xmlDoc $xmlDoc -negateItem:$negateDestination
            $xmlRule.appendChild($xmlDestinations) | out-null
        }

        #Services
        if ( $service) {
            [System.XML.XMLElement]$xmlServices = $XMLDoc.CreateElement("services")
            #Iterate the services passed and build service nodes.
            $xmlRule.appendChild($xmlServices) | out-null
            foreach ( $serviceitem in $service ) {
            
                #Services
                [System.XML.XMLElement]$xmlService = $XMLDoc.CreateElement("service")
                $xmlServices.appendChild($xmlService) | out-null
                Add-XmlElement -xmlRoot $xmlService -xmlElementName "value" -xmlElementText $serviceItem.objectId   
        
            }
        }

        #Applied To
        if ( -not ( $AppliedTo )) { 
            $xmlAppliedToList = New-NsxAppliedToListNode -xmlDoc $xmlDoc -ApplyToDFW 
        }
        else {
            $xmlAppliedToList = New-NsxAppliedToListNode -itemlist $AppliedTo -xmlDoc $xmlDoc 
        }
        $xmlRule.appendChild($xmlAppliedToList) | out-null

        #Tag
        if ( $tag ) {

            Add-XmlElement -xmlRoot $xmlRule -xmlElementName "tag" -xmlElementText $tag
        }
        
        #Append the new rule to the section
        $xmlrule = $Section.ownerDocument.ImportNode($xmlRule, $true)
        switch ($Position) {
            "Top" { $Section.prependchild($xmlRule) | Out-Null }
            "Bottom" { $Section.appendchild($xmlRule) | Out-Null }
        
        }
        #Do the post
        $body = $Section.OuterXml
        $URI = "/api/4.0/firewall/$scopeId/config/$ruletype/$($section.Id)"
        
        #Need the IfMatch header to specify the current section generation id
    
        $IfMatchHeader = @{"If-Match"=$generationNumber}
        $response = invoke-nsxrestmethod -method "put" -uri $URI -body $body -extraheader $IfMatchHeader

        $response.section
        
    }
    end {}
}
Export-ModuleMember -Function New-NsxFirewallRule


function Remove-NsxFirewallRule {

    <#
    .SYNOPSIS
    Removes the specified NSX Distributed Firewall Rule.

    .DESCRIPTION
    An NSX Distributed Firewall Rule defines a typical 5 tuple rule and is 
    enforced on each hypervisor at the point where the VMs NIC connects to the 
    portgroup or logical switch.  

    This cmdlet removes the specified NSX Distributed Firewall Rule. 

    .EXAMPLE
    PS C:\> Get-NsxFirewallRule -RuleId 1144 | Remove-NsxFirewallRule 
        -confirm:$false 

    #>
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNull()]
            [System.Xml.XmlElement]$Rule,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false
    )
    
    begin {

    }

    process {

        if ( $confirm ) { 
            $message  = "Firewall Rule removal is permanent and cannot be reversed."
            $question = "Proceed with removal of Rule $($Rule.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
        
            $section = get-nsxFirewallSection $Rule.parentnode.name
            $generationNumber = $section.generationNumber
            $IfMatchHeader = @{"If-Match"=$generationNumber}
            $URI = "/api/4.0/firewall/globalroot-0/config/$($Section.ParentNode.name.tolower())/$($Section.Id)/rules/$($Rule.id)"
          
            
            Write-Progress -activity "Remove Rule $($Rule.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI  -extraheader $IfMatchHeader | out-null
            write-progress -activity "Remove Rule $($Rule.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxFirewallRule


########
########
# Load Balancing


function Get-NsxLoadBalancer {

    <#
    .SYNOPSIS
    Retrieves the LoadBalancer configuration from a specified Edge.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    This cmdlet retrieves the LoadBalancer configuration from a specified Edge. 
    .EXAMPLE
   
    PS C:\> Get-NsxEdge TestESG | Get-NsxLoadBalancer
    
    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-Edge $_ })]
            [System.Xml.XmlElement]$Edge
    )

    begin {}

    process { 

        #We append the Edge-id to the associated LB XML to enable pipeline workflows and 
        #consistent readable output (PSCustom object approach results in 'edge and 
        #LoadBalancer' props of the output which is not pretty for the user)

        $_LoadBalancer = $Edge.features.loadBalancer.CloneNode($True)
        Add-XmlElement -xmlRoot $_LoadBalancer -xmlElementName "edgeId" -xmlElementText $Edge.Id
        $_LoadBalancer

    }      
}
Export-ModuleMember -Function Get-NsxLoadBalancer

function Set-NsxLoadBalancer {

    <#
    .SYNOPSIS
    Configures an NSX LoadBalancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    This cmdlet sets the basic LoadBalancer configuration of an NSX Load Balancer. 

    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$False)]
            [switch]$Enabled,
        [Parameter (Mandatory=$False)]
            [switch]$EnableAcceleration,
        [Parameter (Mandatory=$False)]
            [switch]$EnableLogging,
        [Parameter (Mandatory=$False)]
            [ValidateSet("emergency","alert","critical","error","warning","notice","info","debug")]
            [string]$LogLevel

    )

    begin {
    }

    process {

        #Create private xml element
        $_LoadBalancer = $LoadBalancer.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_LoadBalancer.edgeId
        $_LoadBalancer.RemoveChild( $($_LoadBalancer.SelectSingleNode('descendant::edgeId')) ) | out-null

        #Using PSBoundParamters.ContainsKey lets us know if the user called us with a given parameter.
        #If the user did not specify a given parameter, we dont want to modify from the existing value.

        if ( $PsBoundParameters.ContainsKey('Enabled') ) {
            if ( $Enabled ) { 
                $_LoadBalancer.enabled = "true" 
            } else { 
                $_LoadBalancer.enabled = "false" 
            } 
        }

        if ( $PsBoundParameters.ContainsKey('EnableAcceleration') ) {
            if ( $EnableAcceleration ) { 
                $_LoadBalancer.accelerationEnabled = "true" 
            } else { 
                $_LoadBalancer.accelerationEnabled = "false" 
            } 
        }

        if ( $PsBoundParameters.ContainsKey('EnableLogging') ) {
            if ( $EnableLogging ) { 
                $_LoadBalancer.logging.enable = "true" 
            } else { 
                $_LoadBalancer.logging.enable = "false" 
            } 
        }

        if ( $PsBoundParameters.ContainsKey('LogLevel') ) {
            $_LoadBalancer.logging.logLevel = $LogLevel
        }

        $URI = "/api/4.0/edges/$($edgeId)/loadbalancer/config"
        $body = $_LoadBalancer.OuterXml 

        Write-Progress -activity "Update Edge Services Gateway $($edgeId)"
        $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
        write-progress -activity "Update Edge Services Gateway $($edgeId)" -completed
        Get-NsxEdge -objectId $($edgeId) | Get-NsxLoadBalancer
    }

    end{
    }
}
Export-ModuleMember -Function Set-NsxLoadBalancer

function Get-NsxLoadBalancerMonitor {

    <#
    .SYNOPSIS
    Retrieves the LoadBalancer Monitors from a specified LoadBalancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    Load Balancer Monitors are the method by which a Load Balancer determines
    the health of pool members.

    This cmdlet retrieves the LoadBalancer Monitors from a specified 
    LoadBalancer.

    .EXAMPLE
   
    PS C:\> $LoadBalancer | Get-NsxLoadBalancerMonitor default_http_monitor
    
    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [PSCustomObject]$LoadBalancer,
        [Parameter (Mandatory=$true,ParameterSetName="monitorId")]
            [string]$monitorId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name
    )

    begin {}

    process { 
        
        if ( $Name) { 
            $Monitors = $loadbalancer.monitor | ? { $_.name -eq $Name }
        }
        elseif ( $monitorId ) { 
            $Monitors = $loadbalancer.monitor | ? { $_.monitorId -eq $monitorId }
        }
        else { 
            $Monitors = $loadbalancer.monitor 
        }

        foreach ( $Monitor in $Monitors ) { 
            $_Monitor = $Monitor.CloneNode($True)
            Add-XmlElement -xmlRoot $_Monitor -xmlElementName "edgeId" -xmlElementText $LoadBalancer.edgeId
            $_Monitor
        }
    }
    end{ }
}
Export-ModuleMember -Function Get-NsxLoadBalancerMonitor

function Get-NsxLoadBalancerApplicationProfile {

    <#
    .SYNOPSIS
    Retrieves LoadBalancer Application Profiles from a specified LoadBalancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    Application profiles define the behavior of a particular type of network 
    traffic. After configuring a profile, you associate the profile with a 
    virtual server. The virtual server then processes traffic according to the 
    values specified in the profile. Using profiles enhances your control over 
    managing network traffic, and makes traffic‐management tasks easier and more
    efficient.
    
    This cmdlet retrieves the LoadBalancer Application Profiles from a specified 
    LoadBalancer.

    .EXAMPLE
   
    PS C:\> Get-NsxEdge LoadBalancer | Get-NsxLoadBalancer | 
        Get-NsxLoadBalancerApplicationProfile HTTP
    
    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$true,ParameterSetName="applicationProfileId")]
            [string]$applicationProfileId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name

    )

    begin {}

    process { 
        
        if ( $PsBoundParameters.ContainsKey('Name')) { 
            $AppProfiles = $loadbalancer.applicationProfile | ? { $_.name -eq $Name }
        }
        elseif ( $PsBoundParameters.ContainsKey('monitorId') ) { 
            $AppProfiles = $loadbalancer.applicationProfile | ? { $_.monitorId -eq $applicationProfileId }
        }
        else { 
            $AppProfiles = $loadbalancer.applicationProfile 
        }

        foreach ( $AppProfile in $AppProfiles ) { 
            $_AppProfile = $AppProfile.CloneNode($True)
            Add-XmlElement -xmlRoot $_AppProfile -xmlElementName "edgeId" -xmlElementText $LoadBalancer.edgeId
            $_AppProfile
        }
    }

    end{ }
}
Export-ModuleMember -Function Get-NsxLoadBalancerApplicationProfile

function New-NsxLoadBalancerApplicationProfile {
 
    <#
    .SYNOPSIS
    Creates a new LoadBalancer Application Profile on the specified 
    Edge Services Gateway.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    Application profiles define the behavior of a particular type of network 
    traffic. After configuring a profile, you associate the profile with a 
    virtual server. The virtual server then processes traffic according to the 
    values specified in the profile. Using profiles enhances your control over 
    managing network traffic, and makes traffic‐management tasks easier and more
    efficient.
    
    This cmdlet creates a new LoadBalancer Application Profile on a specified 
    Load Balancer

    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$True)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$True)]
            [ValidateSet("TCP","UDP","HTTP","HTTPS")]
            [string]$Type,  
        [Parameter (Mandatory=$False)]
            [ValidateNotNullOrEmpty()]
            [switch]$insertXForwardedFor=$false    
        
    )
    # Lot more to do here - need persistence settings dependant on the type selected... as well as cookie settings, and cert selection...

    begin {
    }

    process {
        
        #Create private xml element
        $_LoadBalancer = $LoadBalancer.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_LoadBalancer.edgeId
        $_LoadBalancer.RemoveChild( $($_LoadBalancer.SelectSingleNode('descendant::edgeId')) ) | out-null

        if ( -not $_LoadBalancer.enabled -eq 'true' ) { 
            write-warning "Load Balancer feature is not enabled on edge $($edgeId).  Use Set-NsxLoadBalancer -EnableLoadBalancing to enable."
        }
     
        [System.XML.XMLElement]$xmlapplicationProfile = $_LoadBalancer.OwnerDocument.CreateElement("applicationProfile")
        $_LoadBalancer.appendChild($xmlapplicationProfile) | out-null
     
        Add-XmlElement -xmlRoot $xmlapplicationProfile -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlapplicationProfile -xmlElementName "template" -xmlElementText $Type
        Add-XmlElement -xmlRoot $xmlapplicationProfile -xmlElementName "insertXForwardedFor" -xmlElementText $insertXForwardedFor 
        
        
        $URI = "/api/4.0/edges/$edgeId/loadbalancer/config"
        $body = $_LoadBalancer.OuterXml 
    
        Write-Progress -activity "Update Edge Services Gateway $($edgeId)" -status "Load Balancer Config"
        $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
        write-progress -activity "Update Edge Services Gateway $($edgeId)" -completed

        $updatedEdge = Get-NsxEdge -objectId $($edgeId)
        
        $applicationProfiles = $updatedEdge.features.loadbalancer.applicationProfile
        foreach ($applicationProfile in $applicationProfiles) { 

            #6.1 Bug? NSX API creates an object ID format that it does not accept back when put. We have to change on the fly to the 'correct format'.
            write-debug "$($MyInvocation.MyCommand.Name) : Checking for stupidness in $($applicationProfile.applicationProfileId)"    
            $applicationProfile.applicationProfileId = 
                $applicationProfile.applicationProfileId.replace("edge_load_balancer_application_profiles","applicationProfile-")
            
        }

        $body = $updatedEdge.features.loadbalancer.OuterXml
        Write-Progress -activity "Update Edge Services Gateway $($edgeId)" -status "Load Balancer Config"
        $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
        write-progress -activity "Update Edge Services Gateway $($edgeId)" -completed

        #filter output for our newly created app profile - name is safe as it has to be unique.
        $return = $updatedEdge.features.loadbalancer.applicationProfile | ? { $_.name -eq $name }
        Add-XmlElement -xmlroot $return -xmlElementName "edgeId" -xmlElementText $edgeId
        $return
    }

    end {}
}
Export-ModuleMember -Function New-NsxLoadBalancerApplicationProfile

function New-NsxLoadBalancerMemberSpec {

    <#
    .SYNOPSIS
    Creates a new LoadBalancer Pool Member specification to be used when 
    updating or creating a LoadBalancer Pool

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.  Prior to creating or updating a pool to add a member, a member
    spec describing the member needs to be created.
    
    This cmdlet creates a new LoadBalancer Pool Member specification.

    .EXAMPLE
    
    PS C:\> $WebMember1 = New-NsxLoadBalancerMemberSpec -name Web01 
        -IpAddress 192.168.200.11 -Port 80
    
    PS C:\> $WebMember2 = New-NsxLoadBalancerMemberSpec -name Web02 
        -IpAddress 192.168.200.12 -Port 80 -MonitorPort 8080 
        -MaximumConnections 100
    
    #>


     param (

        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [IpAddress]$IpAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [int]$Weight=1,
        [Parameter (Mandatory=$true)]
            [ValidateRange(1,65535)]
            [int]$Port,   
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65535)]
            [int]$MonitorPort=$port,   
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [int]$MinimumConnections=0,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [int]$MaximumConnections=0
    )

    begin {}
    process { 

        [System.XML.XMLDocument]$xmlDoc = New-Object System.XML.XMLDocument
        [System.XML.XMLElement]$xmlMember = $XMLDoc.CreateElement("member")
        $xmlDoc.appendChild($xmlMember) | out-null

        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "ipAddress" -xmlElementText $IpAddress   
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "weight" -xmlElementText $Weight 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "port" -xmlElementText $port 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "monitorPort" -xmlElementText $port 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "minConn" -xmlElementText $MinimumConnections 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "maxConn" -xmlElementText $MaximumConnections 
  
        $xmlMember

    }

    end {}
}
Export-ModuleMember -Function New-NsxLoadBalancerMemberSpec

function New-NsxLoadBalancerPool {
 

    <#
    .SYNOPSIS
    Creates a new LoadBalancer Pool on the specified ESG.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.  Prior to creating or updating a pool to add a member, a member
    spec describing the member needs to be created.
    
    This cmdlet creates a new LoadBalancer Pool on the specified ESG.

    .EXAMPLE
    Example1: Need to create member specs for each of the pool members first

    PS C:\> $WebMember1 = New-NsxLoadBalancerMemberSpec -name Web01 
        -IpAddress 192.168.200.11 -Port 80
    
    PS C:\> $WebMember2 = New-NsxLoadBalancerMemberSpec -name Web02 
        -IpAddress 192.168.200.12 -Port 80 -MonitorPort 8080 
        -MaximumConnections 100

    PS C:\> $WebPool = $ESG | New-NsxLoadBalancerPool -Name WebPool 
        -Description "WebServer Pool" -Transparent:$false -Algorithm round-robin
        -Monitor $monitor -MemberSpec $WebMember1,$WebMember2
   
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$True)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$False)]
            [ValidateNotNull()]
            [string]$Description="",
        [Parameter (Mandatory=$False)]
            [ValidateNotNullOrEmpty()]
            [switch]$Transparent=$false,
        [Parameter (Mandatory=$True)]
            [ValidateSet("round-robin", "ip-hash", "uri", "leastconn")]
            [string]$Algorithm,
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-LoadBalancerMonitor $_ })]
            [System.Xml.XmlElement]$Monitor,
        [Parameter (Mandatory=$false)]
            [ValidateScript({ Validate-LoadBalancerMemberSpec $_ })]
            [System.Xml.XmlElement[]]$MemberSpec
    )

    begin {
    }

    process {
        
        #Create private xml element
        $_LoadBalancer = $LoadBalancer.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_LoadBalancer.edgeId
        $_LoadBalancer.RemoveChild( $($_LoadBalancer.SelectSingleNode('descendant::edgeId')) ) | out-null

        if ( -not $_LoadBalancer.enabled -eq 'true' ) { 
            write-warning "Load Balancer feature is not enabled on edge $($edgeId).  Use Set-NsxLoadBalancer -EnableLoadBalancing to enable."
        }

        [System.XML.XMLElement]$xmlPool = $_LoadBalancer.OwnerDocument.CreateElement("pool")
        $_LoadBalancer.appendChild($xmlPool) | out-null

     
        Add-XmlElement -xmlRoot $xmlPool -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlPool -xmlElementName "description" -xmlElementText $Description
        Add-XmlElement -xmlRoot $xmlPool -xmlElementName "transparent" -xmlElementText $Transparent 
        Add-XmlElement -xmlRoot $xmlPool -xmlElementName "algorithm" -xmlElementText $algorithm 
        
        if ( $PsBoundParameters.ContainsKey('Monitor')) { 
            Add-XmlElement -xmlRoot $xmlPool -xmlElementName "monitorId" -xmlElementText $Monitor.monitorId 
        }

        if ( $PSBoundParameters.ContainsKey('MemberSpec')) {
            foreach ( $Member in $MemberSpec ) { 
                $xmlmember = $xmlPool.OwnerDocument.ImportNode($Member, $true)
                $xmlPool.AppendChild($xmlmember) | out-null
            }
        }

        $URI = "/api/4.0/edges/$EdgeId/loadbalancer/config"
        $body = $_LoadBalancer.OuterXml 
    
        Write-Progress -activity "Update Edge Services Gateway $($EdgeId)" -status "Load Balancer Config"
        $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
        write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed

        $UpdatedEdge = Get-NsxEdge -objectId $($EdgeId)
        $return = $UpdatedEdge.features.loadBalancer.pool | ? { $_.name -eq $Name }
        Add-XmlElement -xmlroot $return -xmlElementName "edgeId" -xmlElementText $edgeId
        $return
    }

    end {}
}
Export-ModuleMember -Function New-NsxLoadBalancerPool

function Get-NsxLoadBalancerPool {

    <#
    .SYNOPSIS
    Retrieves LoadBalancer Pools Profiles from the specified LoadBalancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.  Prior to creating or updating a pool to add a member, a member
    spec describing the member needs to be created.
    
    This cmdlet retrieves LoadBalancer pools from the specified LoadBalancer.

    .EXAMPLE
   
    PS C:\> Get-NsxEdge | Get-NsxLoadBalancer | 
        Get-NsxLoadBalancerPool
    
    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$true,ParameterSetName="poolId")]
            [string]$PoolId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name

    )

    begin {}

    process { 
        
        if ( $loadbalancer.SelectSingleNode('child::pool')) { 
            if ( $PsBoundParameters.ContainsKey('Name')) {  
                $pools = $loadbalancer.pool | ? { $_.name -eq $Name }
            }
            elseif ( $PsBoundParameters.ContainsKey('PoolId')) {  
                $pools = $loadbalancer.pool | ? { $_.poolId -eq $PoolId }
            }
            else { 
                $pools = $loadbalancer.pool 
            }

            foreach ( $Pool in $Pools ) { 
                $_Pool = $Pool.CloneNode($True)
                Add-XmlElement -xmlRoot $_Pool -xmlElementName "edgeId" -xmlElementText $LoadBalancer.edgeId
                $_Pool
            }
        }
    }

    end{ }
}
Export-ModuleMember -Function Get-NsxLoadBalancerPool

function Remove-NsxLoadBalancerPool {

    <#
    .SYNOPSIS
    Removes a Pool from the specified Load Balancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.
    
    This cmdlet removes the specified pool from the Load Balancer pool and returns
    the updated LoadBalancer.
   
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LoadBalancerPool $_ })]
            [System.Xml.XmlElement]$LoadBalancerPool,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$True
    )

    begin {}
    process { 

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $LoadBalancerPool.edgeId
        $poolId = $LoadBalancerPool.poolId

        #Get and remove the edgeId element
        $LoadBalancer = Get-nsxEdge -objectId $edgeId | Get-NsxLoadBalancer
        $LoadBalancer.RemoveChild( $($LoadBalancer.SelectSingleNode('child::edgeId')) ) | out-null

        $PoolToRemove = $LoadBalancer.SelectSingleNode("child::pool[poolId=`"$poolId`"]")
        if ( -not $PoolToRemove ) {
            throw "Pool $poolId is not defined on Load Balancer $edgeid."
        } 
        
        $LoadBalancer.RemoveChild( $PoolToRemove ) | out-null
            
        $URI = "/api/4.0/edges/$edgeId/loadbalancer/config"
        $body = $LoadBalancer.OuterXml 
        
        if ( $confirm ) { 
            $message  = "Pool removal is permanent."
            $question = "Proceed with removal of Pool $poolId"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $EdgeId" -status "Removing pool $poolId"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $EdgeId" -completed

            Get-NSxEdge -objectID $edgeId | Get-NsxLoadBalancer
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLoadBalancerPool

function Get-NsxLoadBalancerPoolMember {

    <#
    .SYNOPSIS
    Retrieves the members of the specified LoadBalancer Pool.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.  Prior to creating or updating a pool to add a member, a member
    spec describing the member needs to be created.
    
    This cmdlet retrieves the members of the specified LoadBalancer Pool.

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancerPool $_ })]
            [System.Xml.XmlElement]$LoadBalancerPool,
        [Parameter (Mandatory=$true,ParameterSetName="MemberId")]
            [string]$MemberId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name

    )

    begin {}

    process { 
        
        

        if ( $PsBoundParameters.ContainsKey('Name')) {  
            $Members = $LoadBalancerPool.SelectNodes('descendant::member') | ? { $_.name -eq $Name }
        }
        elseif ( $PsBoundParameters.ContainsKey('MemberId')) {  
            $Members = $LoadBalancerPool.SelectNodes('descendant::member') | ? { $_.memberId -eq $MemberId }
        }
        else { 
            $Members = $LoadBalancerPool.SelectNodes('descendant::member') 
        }

        foreach ( $Member in $Members ) { 
            $_Member = $Member.CloneNode($True)
            Add-XmlElement -xmlRoot $_Member -xmlElementName "edgeId" -xmlElementText $LoadBalancerPool.edgeId
            Add-XmlElement -xmlRoot $_Member -xmlElementName "poolId" -xmlElementText $LoadBalancerPool.poolId

            $_Member
        }
    }

    end{ }
}
Export-ModuleMember -Function Get-NsxLoadBalancerPoolMember

function Add-NsxLoadBalancerPoolMember {

    <#
    .SYNOPSIS
    Adds a new Pool Member to the specified Load Balancer Pool.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.
    
    This cmdlet adds a new member to the specified LoadBalancer Pool and
    returns the updated Pool.
   
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancerPool $_ })]
            [System.Xml.XmlElement]$LoadBalancerPool,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$true)]
            [ValidateNotNullOrEmpty()]
            [IpAddress]$IpAddress,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [int]$Weight=1,
        [Parameter (Mandatory=$true)]
            [ValidateRange(1,65535)]
            [int]$Port,   
        [Parameter (Mandatory=$false)]
            [ValidateRange(1,65535)]
            [int]$MonitorPort=$port,   
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [int]$MinimumConnections=0,
        [Parameter (Mandatory=$false)]
            [ValidateNotNullOrEmpty()]
            [int]$MaximumConnections=0
    )

    begin {}
    process { 


        #Create private xml element
        $_LoadBalancerPool = $LoadBalancerPool.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_LoadBalancerPool.edgeId
        $_LoadBalancerPool.RemoveChild( $($_LoadBalancerPool.SelectSingleNode('descendant::edgeId')) ) | out-null

        [System.XML.XMLElement]$xmlMember = $_LoadBalancerPool.OwnerDocument.CreateElement("member")
        $_LoadBalancerPool.appendChild($xmlMember) | out-null

        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "ipAddress" -xmlElementText $IpAddress   
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "weight" -xmlElementText $Weight 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "port" -xmlElementText $port 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "monitorPort" -xmlElementText $port 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "minConn" -xmlElementText $MinimumConnections 
        Add-XmlElement -xmlRoot $xmlMember -xmlElementName "maxConn" -xmlElementText $MaximumConnections 
  
            
        $URI = "/api/4.0/edges/$edgeId/loadbalancer/config/pools/$($_LoadBalancerPool.poolId)"
        $body = $_LoadBalancerPool.OuterXml 
    
        Write-Progress -activity "Update Edge Services Gateway $($EdgeId)" -status "Pool config for $($_LoadBalancerPool.poolId)"
        $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
        write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed

        #Get updated pool
        $URI = "/api/4.0/edges/$edgeId/loadbalancer/config/pools/$($_LoadBalancerPool.poolId)"
        Write-Progress -activity "Retrieving Updated Pool for $($EdgeId)" -status "Pool $($_LoadBalancerPool.poolId)"
        $return = invoke-nsxrestmethod -method "get" -uri $URI
        $Pool = $return.pool
        Add-XmlElement -xmlroot $Pool -xmlElementName "edgeId" -xmlElementText $edgeId
        $Pool

    }

    end {}
}
Export-ModuleMember -Function Add-NsxLoadBalancerPoolMember

function Remove-NsxLoadBalancerPoolMember {

    <#
    .SYNOPSIS
    Removes a Pool Member from the specified Load Balancer Pool.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A pool manages load balancer distribution methods and has a service monitor 
    attached to it for health check parameters.  Each Pool has one or more 
    members.
    
    This cmdlet removes the specified member from the specified pool and returns
     the updated Pool.
   
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LoadBalancerPoolMember $_ })]
            [System.Xml.XmlElement]$LoadBalancerPoolMember,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$True
    )

    begin {}
    process { 

        #Store the edgeId and remove it from the XML as we need to post it...
        $MemberId = $LoadBalancerPoolMember.memberId
        $edgeId = $LoadBalancerPoolMember.edgeId
        $poolId = $LoadBalancerPoolMember.poolId

        #Get and remove the edgeId and poolId elements
        $LoadBalancer = Get-nsxEdge -objectId $edgeId | Get-NsxLoadBalancer
        $LoadBalancer.RemoveChild( $($LoadBalancer.SelectSingleNode('child::edgeId')) ) | out-null

        $LoadBalancerPool = $loadbalancer.SelectSingleNode("child::pool[poolId=`"$poolId`"]")

        $MemberToRemove = $LoadBalancerPool.SelectSingleNode("child::member[memberId=`"$MemberId`"]")
        if ( -not $MemberToRemove ) {
            throw "Member $MemberId is not a member of pool $PoolId."
        } 
        
        $LoadBalancerPool.RemoveChild( $MemberToRemove ) | out-null
            
        $URI = "/api/4.0/edges/$edgeId/loadbalancer/config"
        $body = $LoadBalancer.OuterXml 
        
        if ( $confirm ) { 
            $message  = "Pool Member removal is permanent."
            $question = "Proceed with removal of Pool Member $memberId?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $EdgeId" -status "Pool config for $poolId"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $EdgeId" -completed

            Get-NSxEdge -objectID $edgeId | Get-NsxLoadBalancer | Get-NsxLoadBalancerPool -poolId $poolId
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLoadBalancerPoolMember

function Get-NsxLoadBalancerVip {

    <#
    .SYNOPSIS
    Retrieves the Virtual Servers configured on the specified LoadBalancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A Virtual Server binds an IP address (must already exist on an ESG iNterface as 
    either a Primary or Secondary Address) and a port to a LoadBalancer Pool and 
    Application Profile.

    This cmdlet retrieves the configured Virtual Servers from the specified Load 
    Balancer.

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]

    param (
        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$true,ParameterSetName="VirtualServerId")]
            [string]$VirtualServerId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name
    )

    begin {}

    process { 
        

        if ( $PsBoundParameters.ContainsKey('Name')) {  
            $Vips = $LoadBalancer.SelectNodes('descendant::virtualServer') | ? { $_.name -eq $Name }
        }
        elseif ( $PsBoundParameters.ContainsKey('MemberId')) {  
            $Vips = $LoadBalancer.SelectNodes('descendant::virtualServer') | ? { $_.virtualServerId -eq $VirtualServerId }
        }
        else { 
            $Vips = $LoadBalancer.SelectNodes('descendant::virtualServer') 
        }

        foreach ( $Vip in $Vips ) { 
            $_Vip = $VIP.CloneNode($True)
            Add-XmlElement -xmlRoot $_Vip -xmlElementName "edgeId" -xmlElementText $LoadBalancer.edgeId
            $_Vip
        }
    }

    end{ }
}
Export-ModuleMember -Function Get-NsxLoadBalancerVip

function Add-NsxLoadBalancerVip {

    <#
    .SYNOPSIS
    Adds a new LoadBalancer Virtual Server to the specified ESG.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A Virtual Server binds an IP address (must already exist on an ESG iNterface as 
    either a Primary or Secondary Address) and a port to a LoadBalancer Pool and 
    Application Profile.

    This cmdlet creates a new Load Balancer VIP.

    .EXAMPLE
    Example1: Need to create member specs for each of the pool members first

    PS C:\> $WebVip = Get-NsxEdge DMZ_Edge_2 | 
        New-NsxLoadBalancerVip -Name WebVip -Description "Test Creating a VIP" 
        -IpAddress $edge_uplink_ip -Protocol http -Port 80 
        -ApplicationProfile $AppProfile -DefaultPool $WebPool 
        -AccelerationEnabled
   
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateScript({ Validate-LoadBalancer $_ })]
            [System.Xml.XmlElement]$LoadBalancer,
        [Parameter (Mandatory=$True)]
            [ValidateNotNullOrEmpty()]
            [string]$Name,
        [Parameter (Mandatory=$False)]
            [ValidateNotNull()]
            [string]$Description="",
        [Parameter (Mandatory=$True)]
            [ValidateNotNullOrEmpty()]
            [IpAddress]$IpAddress,
        [Parameter (Mandatory=$True)]
            [ValidateSet("http", "https", "tcp", "udp")]
            [string]$Protocol,
        [Parameter (Mandatory=$True)]
            [ValidateRange(1,65535)]
            [int]$Port,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullorEmpty()]
            [switch]$Enabled=$true,        
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LoadBalancerApplicationProfile $_ })]
            [System.Xml.XmlElement]$ApplicationProfile,
        [Parameter (Mandatory=$true)]
            [ValidateScript({ Validate-LoadBalancerPool $_ })]
            [System.Xml.XmlElement]$DefaultPool,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullOrEmpty()]
            [switch]$AccelerationEnabled=$True,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullOrEmpty()]
            [int]$ConnectionLimit=0,
        [Parameter (Mandatory=$False)]
            [ValidateNotNullOrEmpty()]
            [int]$ConnectionRateLimit=0
        
    )

    begin {
    }

    process {
        

        #Create private xml element
        $_LoadBalancer = $LoadBalancer.CloneNode($true)

        #Store the edgeId and remove it from the XML as we need to post it...
        $edgeId = $_LoadBalancer.edgeId
        $_LoadBalancer.RemoveChild( $($_LoadBalancer.SelectSingleNode('descendant::edgeId')) ) | out-null

        if ( -not $_LoadBalancer.enabled -eq 'true' ) { 
            write-warning "Load Balancer feature is not enabled on edge $($edgeId).  Use Set-NsxLoadBalancer -EnableLoadBalancing to enable."
        }

        [System.XML.XMLElement]$xmlVIip = $_LoadBalancer.OwnerDocument.CreateElement("virtualServer")
        $_LoadBalancer.appendChild($xmlVIip) | out-null

     
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "name" -xmlElementText $Name
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "description" -xmlElementText $Description
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "enabled" -xmlElementText $Enabled 
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "ipAddress" -xmlElementText $IpAddress 
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "protocol" -xmlElementText $Protocol 
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "port" -xmlElementText $Port 
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "connectionLimit" -xmlElementText $ConnectionLimit 
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "connectionRateLimit" -xmlElementText $ConnectionRateLimit 
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "applicationProfileId" -xmlElementText $ApplicationProfile.applicationProfileId
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "defaultPoolId" -xmlElementText $DefaultPool.poolId
        Add-XmlElement -xmlRoot $xmlVIip -xmlElementName "accelerationEnabled" -xmlElementText $AccelerationEnabled

            
        $URI = "/api/4.0/edges/$($EdgeId)/loadbalancer/config"
        $body = $_LoadBalancer.OuterXml 
    
        Write-Progress -activity "Update Edge Services Gateway $EdgeId" -status "Load Balancer Config"
        $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
        write-progress -activity "Update Edge Services Gateway $EdgeId" -completed

        $UpdatedLB = Get-NsxEdge -objectId $EdgeId | Get-NsxLoadBalancer
        $UpdatedLB

    }

    end {}
}
Export-ModuleMember -Function Add-NsxLoadBalancerVip

function Remove-NsxLoadBalancerVip {

    <#
    .SYNOPSIS
    Removes a VIP from the specified Load Balancer.

    .DESCRIPTION
    An NSX Edge Service Gateway provides all NSX Edge services such as firewall,
    NAT, DHCP, VPN, load balancing, and high availability. 

    The NSX Edge load balancer enables network traffic to follow multiple paths
    to a specific destination. It distributes incoming service requests evenly 
    among multiple servers in such a way that the load distribution is 
    transparent to users. Load balancing thus helps in achieving optimal 
    resource utilization, maximizing throughput, minimizing response time, and 
    avoiding overload. NSX Edge provides load balancing up to Layer 7.

    A Virtual Server binds an IP address (must already exist on an ESG iNterface as 
    either a Primary or Secondary Address) and a port to a LoadBalancer Pool and 
    Application Profile.

    This cmdlet remove a VIP from the specified Load Balancer.

    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({ Validate-LoadBalancerVip $_ })]
            [System.Xml.XmlElement]$LoadBalancerVip,
        [Parameter (Mandatory=$False)]
            [switch]$Confirm=$True
        
    )

    begin {
    }

    process {
        


        #Store the virtualserverid and edgeId and remove it from the LB XML as we need to post it...
        $VipId = $LoadBalancerVip.VirtualServerId
        $edgeId = $LoadBalancerVip.edgeId

        $LoadBalancer = Get-nsxEdge -objectId $edgeId | Get-NsxLoadBalancer
        $LoadBalancer.RemoveChild( $($LoadBalancer.SelectSingleNode('child::edgeId')) ) | out-null

        $VIPToRemove = $LoadBalancer.SelectSingleNode("child::virtualServer[virtualServerId=`"$VipId`"]")
        if ( -not $VIPToRemove ) {
            throw "VIP $VipId is not defined on Edge $edgeId"
        } 
        $LoadBalancer.RemoveChild( $VIPToRemove ) | out-null
            
        $URI = "/api/4.0/edges/$edgeId/loadbalancer/config"
        $body = $LoadBalancer.OuterXml 
    
        if ( $confirm ) { 
            $message  = "VIP removal is permanent."
            $question = "Proceed with removal of VIP $VipID ob Edge $edgeId?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            Write-Progress -activity "Update Edge Services Gateway $($EdgeId)" -status "Removing VIP $VipId"
            $response = invoke-nsxwebrequest -method "put" -uri $URI -body $body
            write-progress -activity "Update Edge Services Gateway $($EdgeId)" -completed

            #Get updated loadbalancer
            $URI = "/api/4.0/edges/$edgeId/loadbalancer/config"
            Write-Progress -activity "Retrieving Updated Load Balancer for $($EdgeId)"
            $return = invoke-nsxrestmethod -method "get" -uri $URI
            $lb = $return.loadBalancer
            Add-XmlElement -xmlroot $lb -xmlElementName "edgeId" -xmlElementText $edgeId
            $lb
        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxLoadBalancerVip



########
########
# Service Composer functions

function Get-NsxSecurityPolicy {

 <#
    .SYNOPSIS
    Retrieves NSX Security Policy

    .DESCRIPTION
    An NSX Security Policy is a set of Endpoint, firewall, and network 
    introspection services that can be applied to a security group.

    This cmdlet returns Security Policy objects.

    .EXAMPLE
    PS C:\> Get-NsxSecurityPolicy SecPolicy_WebServers

    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$false,ParameterSetName="objectId")]
            [string]$ObjectId,
        [Parameter (Mandatory=$false,ParameterSetName="Name",Position=1)]
            [string]$Name,
        [Parameter (Mandatory=$false)]
            [switch]$ShowHidden=$False
    )
    
    begin {}

    process {
     
        if ( -not $objectId ) { 
            #All Security Policies
            $URI = "/api/2.0/services/policy/securitypolicy/all"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            if  ( $Name  ) { 
                $FinalSecPol = $response.securityPolicies.securityPolicy | ? { $_.name -eq $Name }
            } else {
                $FinalSecPol = $response.securityPolicies.securityPolicy
            }

        }
        else {

            #Just getting a single Security group
            $URI = "/api/2.0/services/policy/securitypolicy/$objectId"
            $response = invoke-nsxrestmethod -method "get" -uri $URI
            $FinalSecPol = $response.securityPolicy 
        }

        if ( -not $ShowHidden ) { 
            foreach ( $CurrSecPol in $FinalSecPol ) { 
                if ( $CurrSecPol.SelectSingleNode('child::extendedAttributes/extendedAttribute')) {
                    $hiddenattr = $CurrSecPol.extendedAttributes.extendedAttribute | ? { $_.name -eq 'isHidden'}
                    if ( -not ($hiddenAttr.Value -eq 'true')){
                        $CurrSecPol
                    }
                }
                else { 
                    $CurrSecPol
                }
            }
        }
        else {
            $FinalSecPol
        }
    }
    end {}
}
Export-ModuleMember -Function Get-NsxSecurityPolicy

function Remove-NsxSecurityPolicy {

    <#
    .SYNOPSIS
    Removes the specified NSX Security Policy.

    .DESCRIPTION
    An NSX Security Policy is a set of Endpoint, firewall, and network 
    introspection services that can be applied to a security group.

    This cmdlet removes the specified Security Policy object.


    .EXAMPLE
    Example1: Remove the SecurityPolicy TestSP
    PS C:\> Get-NsxSecurityPolicy TestSP | Remove-NsxSecurityPolicy

    Example2: Remove the SecurityPolicy $sp without confirmation.
    PS C:\> $sp | Remove-NsxSecurityPolicy -confirm:$false

    
    #>

    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true,Position=1)]
            [ValidateNotNullOrEmpty()]
            [System.Xml.XmlElement]$SecurityPolicy,
        [Parameter (Mandatory=$False)]
            [switch]$confirm=$true,
        [Parameter (Mandatory=$False)]
            [switch]$force=$false
    )
    
    begin {}

    process {

        if ( $confirm ) { 
            $message  = "Security Policy removal is permanent."
            $question = "Proceed with removal of Security Policy $($SecurityPolicy.Name)?"

            $choices = New-Object Collections.ObjectModel.Collection[Management.Automation.Host.ChoiceDescription]
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&Yes'))
            $choices.Add((New-Object Management.Automation.Host.ChoiceDescription -ArgumentList '&No'))

            $decision = $Host.UI.PromptForChoice($message, $question, $choices, 1)
        }
        else { $decision = 0 } 
        if ($decision -eq 0) {
            if ( $force ) { 
                $URI = "/api/2.0/services/policy/securitypolicy/$($SecurityPolicy.objectId)?force=true"
            }
            else {
                $URI = "/api/2.0/services/policy/securitypolicy/$($SecurityPolicy.ObjectId)?force=false"
            }
            
            Write-Progress -activity "Remove Security Policy $($SecurityPolicy.Name)"
            invoke-nsxrestmethod -method "delete" -uri $URI | out-null
            write-progress -activity "Remove Security Policy $($SecurityPolicy.Name)" -completed

        }
    }

    end {}
}
Export-ModuleMember -Function Remove-NsxSecurityPolicy

########
########
# Extra functions - here we try to extend on the capability of the base API, rather than just exposing it...


function Get-NsxSecurityGroupEffectiveMembers {

    <#
    .SYNOPSIS
    Determines the effective memebership of a security group including dynamic
    members.

    .DESCRIPTION
    An NSX SecurityGroup can contain members (VMs, IP Addresses, MAC Addresses 
    or interfaces) by virtue of static or dynamic inclusion.  This cmdlet determines 
    the static and dynamic membership of a given group.

    .EXAMPLE
   
    PS C:\>  Get-NsxSecurityGroup TestSG | Get-NsxSecurityGroupEffectiveMembers
   
    #>

    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateNotNull()]
            [System.Xml.XmlElement]$SecurityGroup

    )
    
    begin {

    }

    process {
     
        if ( $securityGroup| get-member -MemberType Properties -Name member ) { $StaticIncludes = $SecurityGroup.member } else { $StaticIncludes = $null }

        #Have to construct Dynamic Includes:
        #GET https://<nsxmgr-ip>/api/2.0/services/securitygroup/ObjectID/translation/virtualmachines 
        #GET https://<nsxmgr-ip>/api/2.0/services/securitygroup/ObjectID/translation/ipaddresses 
        #GET https://<nsxmgr-ip>/api/2.0/services/securitygroup/ObjectID/translation/macaddresses 
        #GET https://<nsxmgr-ip>/api/2.0/services/securitygroup/ObjectID/translation/vnics

        write-debug "$($MyInvocation.MyCommand.Name) : Getting virtualmachine dynamic includes for SG $($SecurityGroup.Name)"
        $URI = "/api/2.0/services/securitygroup/$($SecurityGroup.ObjectId)/translation/virtualmachines"
        $response = invoke-nsxrestmethod -method "get" -uri $URI
        if ( $response.GetElementsByTagName("vmnodes").haschildnodes) { $dynamicVMNodes = $response.GetElementsByTagName("vmnodes")} else { $dynamicVMNodes = $null }

         write-debug "$($MyInvocation.MyCommand.Name) : Getting ipaddress dynamic includes for SG $($SecurityGroup.Name)"
        $URI = "/api/2.0/services/securitygroup/$($SecurityGroup.ObjectId)/translation/ipaddresses"
        $response = invoke-nsxrestmethod -method "get" -uri $URI
        if ( $response.GetElementsByTagName("ipNodes").haschildnodes) { $dynamicIPNodes = $response.GetElementsByTagName("ipNodes") } else { $dynamicIPNodes = $null}

         write-debug "$($MyInvocation.MyCommand.Name) : Getting macaddress dynamic includes for SG $($SecurityGroup.Name)"
        $URI = "/api/2.0/services/securitygroup/$($SecurityGroup.ObjectId)/translation/macaddresses"
        $response = invoke-nsxrestmethod -method "get" -uri $URI
        if ( $response.GetElementsByTagName("macNodes").haschildnodes) { $dynamicMACNodes = $response.GetElementsByTagName("macNodes")} else { $dynamicMACNodes = $null}

         write-debug "$($MyInvocation.MyCommand.Name) : Getting VNIC dynamic includes for SG $($SecurityGroup.Name)"
        $URI = "/api/2.0/services/securitygroup/$($SecurityGroup.ObjectId)/translation/vnics"
        $response = invoke-nsxrestmethod -method "get" -uri $URI
        if ( $response.GetElementsByTagName("vnicNodes").haschildnodes) { $dynamicVNICNodes = $response.GetElementsByTagName("vnicNodes")} else { $dynamicVNICNodes = $null }

        $return = New-Object psobject
        $return | add-member -memberType NoteProperty -Name "StaticInclude" -value $StaticIncludes
        $return | add-member -memberType NoteProperty -Name "DynamicIncludeVM" -value $dynamicVMNodes
        $return | add-member -memberType NoteProperty -Name "DynamicIncludeIP" -value $dynamicIPNodes
        $return | add-member -memberType NoteProperty -Name "DynamicIncludeMAC" -value $dynamicMACNodes
        $return | add-member -memberType NoteProperty -Name "DynamicIncludeVNIC" -value $dynamicVNICNodes
        
        $return

    
    }

    end {}

}
Export-ModuleMember -Function Get-NsxSecurityGroupEffectiveMembers


function Where-NsxVMUsed {

    <#
    .SYNOPSIS
    Determines what what NSX Security Groups or Firewall Rules a given VM is 
    defined in.

    .DESCRIPTION
    Determining what NSX Security Groups or Firewall Rules a given VM is 
    defined in is difficult from the UI.

    This cmdlet provides this simple functionality.


    .EXAMPLE
   
    PS C:\>  Get-VM web01 | Where-NsxVMUsed

    #>


    [CmdLetBinding(DefaultParameterSetName="Name")]
 
    param (

        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VM
    )
    
    begin {

    }

    process {
     
        #Get Firewall rules
        $L3FirewallRules = Get-nsxFirewallSection | Get-NsxFirewallRule 
        $L2FirewallRules = Get-nsxFirewallSection -sectionType layer2sections  | Get-NsxFirewallRule -ruletype layer2sections

        #Get all SGs
        $securityGroups = Get-NsxSecuritygroup
        $MatchedSG = @()
        $MatchedFWL3 = @()
        $MatchedFWL2 = @()
        foreach ( $SecurityGroup in $securityGroups ) {

            $Members = $securityGroup | Get-NsxSecurityGroupEffectiveMembers

            write-debug "$($MyInvocation.MyCommand.Name) : Checking securitygroup $($securitygroup.name) for VM $($VM.name)"
                    
            If ( $members.DynamicIncludeVM ) {
                foreach ( $member in $members.DynamicIncludeVM) {
                    if ( $member.vmnode.vmid -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedSG += $SecurityGroup
                    }
                }
            }
        }

        write-debug "$($MyInvocation.MyCommand.Name) : Checking L3 FirewallRules for VM $($VM.name)"
        foreach ( $FirewallRule in $L3FirewallRules ) {

            write-debug "$($MyInvocation.MyCommand.Name) : Checking rule $($FirewallRule.Id) for VM $($VM.name)"
                
            If ( $FirewallRule | Get-Member -MemberType Properties -Name Sources) {
                foreach ( $Source in $FirewallRule.Sources.Source) {
                    if ( $Source.value -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedFWL3 += $FirewallRule
                    }
                }
            }   
            If ( $FirewallRule| Get-Member -MemberType Properties -Name Destinations ) {
                foreach ( $Dest in $FirewallRule.Destinations.Destination) {
                    if ( $Dest.value -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedFWL3 += $FirewallRule
                    }
                }
            }
            If ( $FirewallRule | Get-Member -MemberType Properties -Name AppliedToList) {
                foreach ( $AppliedTo in $FirewallRule.AppliedToList.AppliedTo) {
                    if ( $AppliedTo.value -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedFWL3 += $FirewallRule
                    }
                }
            }
        }

        write-debug "$($MyInvocation.MyCommand.Name) : Checking L2 FirewallRules for VM $($VM.name)"
        foreach ( $FirewallRule in $L2FirewallRules ) {

            write-debug "$($MyInvocation.MyCommand.Name) : Checking rule $($FirewallRule.Id) for VM $($VM.name)"
                
            If ( $FirewallRule | Get-Member -MemberType Properties -Name Sources) {
                foreach ( $Source in $FirewallRule.Sources.Source) {
                    if ( $Source.value -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedFWL2 += $FirewallRule
                    }
                }
            }   
            If ( $FirewallRule | Get-Member -MemberType Properties -Name Destinations ) {
                foreach ( $Dest in $FirewallRule.Destinations.Destination) {
                    if ( $Dest.value -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedFWL2 += $FirewallRule
                    }
                }
            }
            If ( $FirewallRule | Get-Member -MemberType Properties -Name AppliedToList) {
                foreach ( $AppliedTo in $FirewallRule.AppliedToList.AppliedTo) {
                    if ( $AppliedTo.value -eq $VM.ExtensionData.MoRef.Value ) {
                        $MatchedFWL2 += $FirewallRule
                    }
                }
            }
        }         

        $return = new-object psobject
        $return | add-member -memberType NoteProperty -Name "MatchedSecurityGroups" -value $MatchedSG
        $return | add-member -memberType NoteProperty -Name "MatchedL3FirewallRules" -value $MatchedFWL3
        $return | add-member -memberType NoteProperty -Name "MatchedL2FirewallRules" -value $MatchedFWL2
          
        $return

    }

    end {}

}
Export-ModuleMember -Function Where-NsxVMUsed

function Get-NsxBackingPortGroup{

    <#
    .SYNOPSIS
    Gets the PortGroups backing an NSX Logical Switch.

    .DESCRIPTION
    NSX Logical switches are backed by one or more Virtual Distributed Switch 
    portgroups that are the connection point in vCenter for VMs that connect to 
    the logical switch.

    In simpler environments, a logical switch may only be backed by a single 
    portgroup on a single Virtual Distributed Switch, but the scope of a logical
    switch is governed by the transport zone it is created in.  The transport 
    zone may span multiple vSphere clusters that have hosts that belong to 
    multiple different Virtual Distributed Switches and in this situation, a 
    logical switch would be backed by a unique portgroup on each Virtual 
    Distributed Switch.

    This cmdlet requires an active and correct PowerCLI connection to the 
    vCenter server that is registered to NSX.  It returns PowerCLI VDPortgroup 
    objects for each backing portgroup.
    
    .EXAMPLE

    
    #>


     param (
        
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({Validate-LogicalSwitch $_ })]
            [object]$LogicalSwitch
    )

    begin {

        if ( -not ( $global:DefaultVIServer.IsConnected )) {
            throw "This cmdlet requires a valid PowerCLI connection.  Use Connect-VIServer to connect to vCenter and try again."
        }
    }

    process { 

        $BackingVDS = $_.vdsContextWithBacking
        foreach ( $vDS in $BackingVDS ) { 

            write-debug "$($MyInvocation.MyCommand.Name) : Backing portgroup id $($vDS.backingValue)"

            try {
                Get-VDPortgroup -Id "DistributedVirtualPortgroup-$($vDS.backingValue)"
            }
            catch {
                throw "VDPortgroup not found on connected vCenter $($global:DefaultVIServer.Name).  $_"
            }
        }
    }

    end {}

}
Export-ModuleMember -Function Get-NsxBackingPortGroup

function Get-NsxBackingDVSwitch{

    <#
    .SYNOPSIS
    Gets the Virtual Distributed Switches backing an NSX Logical Switch.

    .DESCRIPTION
    NSX Logical switches are backed by one or more Virtual Distributed Switch 
    portgroups that are the connection point in vCenter for VMs that connect to 
    the logical switch.

    In simpler environments, a logical switch may only be backed by a single 
    portgroup on a single Virtual Distributed Switch, but the scope of a logical
    switch is governed by the transport zone it is created in.  The transport 
    zone may span multiple vSphere clusters that have hosts that belong to 
    multiple different Virtual Distributed Switches and in this situation, a 
    logical switch would be backed by a unique portgroup on each Virtual 
    Distributed Switch.

    This cmdlet requires an active and correct PowerCLI connection to the 
    vCenter server that is registered to NSX.  It returns PowerCLI VDSwitch 
    objects for each backing VDSwitch.
    
    .EXAMPLE

    
    #>


     param (
        
        [Parameter (Mandatory=$true,ValueFromPipeline=$true)]
            [ValidateScript({Validate-LogicalSwitch $_ })]
            [object]$LogicalSwitch
    )

    begin {

        if ( -not ( $global:DefaultVIServer.IsConnected )) {
            throw "This cmdlet requires a valid PowerCLI connection.  Use Connect-VIServer to connect to vCenter and try again."
        }
    }

    process { 

        $BackingVDS = $_.vdsContextWithBacking
        foreach ( $vDS in $BackingVDS ) { 

            write-debug "$($MyInvocation.MyCommand.Name) : Backing vDS id $($vDS.switch.objectId)"

            try {
                Get-VDSwitch -Id "VmwareDistributedVirtualSwitch-$($vDS.switch.objectId)"
            }
            catch {
                throw "VDSwitch not found on connected vCenter $($global:DefaultVIServer.Name).  $_"
            }
        }
    }

    end {}

}
Export-ModuleMember -Function Get-NsxBackingDVSwitch
