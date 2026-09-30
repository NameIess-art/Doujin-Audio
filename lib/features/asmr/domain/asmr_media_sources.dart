const List<String> asmrApiDomains = [
  'https://api.asmr-300.com',
  'https://api.asmr-200.com',
  'https://api.asmr-100.com',
  'https://api.asmr.one',
];

bool isAsmrApiHost(String host) => asmrApiDomains.any(
  (domain) => Uri.parse(domain).host == host.toLowerCase(),
);
