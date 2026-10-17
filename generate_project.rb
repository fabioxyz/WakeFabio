# Compatibility entry point: project.yml is the single project specification.
# On macOS: brew install xcodegen
Dir.chdir(__dir__) do
  exec('xcodegen', 'generate', '--spec', 'project.yml')
end
