export PS1='\[\e[1;32m\]lab\[\e[0m\]:\w# '
[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion
command -v kubectl >/dev/null && . <(kubectl completion bash)

if [ ! -f /tmp/lab-ready ] && [ ! -f /tmp/lab-failed ]; then
  echo "Preparing the lab (starting Docker and loading images). This takes about a minute..."
  while [ ! -f /tmp/lab-ready ] && [ ! -f /tmp/lab-failed ]; do
    sleep 2
  done
fi

if [ -f /tmp/lab-failed ]; then
  echo "Lab setup failed. Read /var/log/lab-setup.log and /var/log/dockerd.log"
else
  echo ""
  echo "Lab is ready."
  echo "  Part 1: less /lab/README-1-docker-namespaces-networking.md"
  echo "  Part 2: less /lab/README-2-kubernetes-from-scratch.md"
  echo ""
fi
