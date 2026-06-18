BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '..' 'src' 'function-app' 'modules' 'TokenService.psm1'
    Import-Module $modulePath -Force

    # Cross-platform self-signed certificate (runs on the Linux CI runner; no Windows-only cmdlets).
    $rsa = [System.Security.Cryptography.RSA]::Create(2048)
    $req = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
        'CN=test-hso-mpc-integration', $rsa,
        [System.Security.Cryptography.HashAlgorithmName]::SHA256,
        [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    $script:TestCert = $req.CreateSelfSigned([DateTimeOffset]::UtcNow.AddDays(-1), [DateTimeOffset]::UtcNow.AddDays(30))
}

Describe 'TokenService — New-ClientAssertionJwt' {
    It 'returns a three-part JWT string' {
        $jwt = New-ClientAssertionJwt -Certificate $script:TestCert `
            -ClientId '00000000-0000-0000-0000-000000000000' `
            -TenantId '11111111-1111-1111-1111-111111111111'
        ($jwt -split '\.').Count | Should -Be 3
    }

    It 'uses the RS256 header with an x5t thumbprint' {
        $jwt = New-ClientAssertionJwt -Certificate $script:TestCert `
            -ClientId '00000000-0000-0000-0000-000000000000' `
            -TenantId '11111111-1111-1111-1111-111111111111'
        $part = ($jwt -split '\.')[0].Replace('-', '+').Replace('_', '/')
        switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        $header = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        $header.alg | Should -Be 'RS256'
        $header.typ | Should -Be 'JWT'
        $header.x5t | Should -Not -BeNullOrEmpty
    }

    It 'targets the tenant token endpoint as audience and the client as issuer/subject' {
        $tenantId = '11111111-1111-1111-1111-111111111111'
        $jwt = New-ClientAssertionJwt -Certificate $script:TestCert `
            -ClientId '00000000-0000-0000-0000-000000000000' -TenantId $tenantId
        $part = ($jwt -split '\.')[1].Replace('-', '+').Replace('_', '/')
        switch ($part.Length % 4) { 2 { $part += '==' } 3 { $part += '=' } }
        $payload = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($part)) | ConvertFrom-Json
        $payload.aud | Should -Be "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
        $payload.iss | Should -Be '00000000-0000-0000-0000-000000000000'
        $payload.sub | Should -Be '00000000-0000-0000-0000-000000000000'
    }

    It 'produces a signature verifiable with the certificate public key' {
        $jwt = New-ClientAssertionJwt -Certificate $script:TestCert `
            -ClientId '00000000-0000-0000-0000-000000000000' `
            -TenantId '11111111-1111-1111-1111-111111111111'
        $parts = $jwt -split '\.'
        $signingInput = [System.Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])")
        $sig = $parts[2].Replace('-', '+').Replace('_', '/')
        switch ($sig.Length % 4) { 2 { $sig += '==' } 3 { $sig += '=' } }
        $sigBytes = [Convert]::FromBase64String($sig)
        $pub = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPublicKey($script:TestCert)
        $pub.VerifyData($signingInput, $sigBytes,
            [System.Security.Cryptography.HashAlgorithmName]::SHA256,
            [System.Security.Cryptography.RSASignaturePadding]::Pkcs1) | Should -BeTrue
    }
}
