Pod::Spec.new do |spec|
spec.name         = "AlgorigoBleLibrary"
spec.version      = "0.2.4"
spec.summary      = "Swift Ble Library using RxSwift by Algorigo"
spec.description  = <<-DESC
Swift Ble Library using RxSwift by Algorigo
write by rouddy@naver.com
DESC

spec.homepage     = "https://github.com/Algorigo/AlgorigoBleSwift"
spec.license      = { :type => 'MIT', :file => 'LICENSE.md' }
spec.author       = { "author" => "rouddy@naver.com" }
spec.documentation_url = "https://github.com/Algorigo/AlgorigoBleSwift"

spec.ios.deployment_target = '11.0'

spec.swift_version = '5.1'
spec.source       = { :git => "https://github.com/Algorigo/AlgorigoBleSwift.git", :tag => "#{spec.version}" }
spec.source_files  = "AlgorigoBleLibrary/AlgorigoBleLibrary/*.swift"

spec.dependency 'RxSwift', '~> 6.5.0'
spec.dependency 'RxRelay', '~> 6.5.0'

spec.dependency 'NordicWiFiProvisioner-BLE', '~> 2.1.1'

end
