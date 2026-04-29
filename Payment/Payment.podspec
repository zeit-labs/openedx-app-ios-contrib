Pod::Spec.new do |spec|
  spec.name             = 'Payment'
  spec.version          = '0.0.1'
  spec.summary          = 'In-App Purchase module for Open edX iOS.'
  spec.description      = 'StoreKit 2 purchases, receipt validation, enrollment sync.'
  spec.homepage         = 'https://github.com/openedx/openedx-app-ios'
  spec.license          = { :type => 'Apache-2.0', :file => '../LICENSE' }
  spec.author           = { 'openedx' => 'oscm@axim.org' }
  spec.ios.deployment_target = '16.0'
  spec.swift_version    = '5.9'
  spec.source_files     = 'Payment/**/*.swift'
  spec.exclude_files    = 'Payment/PaymentTests/**'
  spec.dependency 'Alamofire'
  spec.dependency 'Swinject'
  spec.dependency 'Core'
  spec.dependency 'Theme'
  spec.dependency 'OEXFoundation' # <--- ADDED THIS
end
