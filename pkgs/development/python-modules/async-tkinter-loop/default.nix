{
  lib,
  buildPythonPackage,
  fetchPypi,
  poetry-core,
  tkinter,
  typing-extensions,
}:

buildPythonPackage rec {
  pname = "async-tkinter-loop";
  version = "0.9.3";
  format = "pyproject";

  src = fetchPypi {
    inherit version;
    pname = "async_tkinter_loop";
    hash = "sha256-UJxBgTmEe8suR6WmttJKLi3KKQvEaNrWtrgCnoqGW/0=";
  };

  nativeBuildInputs = [
    poetry-core
  ];

  propagatedBuildInputs = [
    tkinter
    typing-extensions
  ];

  pythonRemoveDeps = [ "asyncio" ];

  pythonImportsCheck = [ "async_tkinter_loop" ];

  meta = with lib; {
    description = "Implementation of asynchronous mainloop for tkinter, the use of which allows using async handler functions";
    homepage = "https://github.com/insolor/async-tkinter-loop";
    changelog = "https://github.com/insolor/async-tkinter-loop/releases/tag/${version}";
    license = licenses.mit;
    maintainers = with maintainers; [ AngryAnt ];
  };
}
