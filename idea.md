# Project idea

 You never actually "mount" in Zed either. The local-feeling you describe is the thin-client illusion: Zed runs a server on the remote that does all file IO/search/LSP, and your local
 window just draws its output over the ssh connection. ssh proxcode → tmux attach → nvim produces exactly that impression — your local terminal shows a "local-feeling" editor that
 physically lives on the remote. Same mechanism, different chrome (terminal instead of GUI).

