setup_file() {
  PROJECT_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  export PROJECT_ROOT
  export PATH="$(dirname "${BATS_TEST_FILENAME}")/helpers/bin:${PATH}"
}
