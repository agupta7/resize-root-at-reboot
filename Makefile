PREFIX ?= /usr/local
BINDIR := $(PREFIX)/bin
SCRIPT_NAME := reboot_resize.sh
INSTALL_NAME := reboot_resize

.PHONY: all install uninstall clean help

all: help

help:
	@echo "Makefile for the reboot_resize tool"
	@echo "Manages the installation of the $(SCRIPT_NAME) script."
	@echo ""
	@echo "Targets:"
	@echo "  install    - Install $(SCRIPT_NAME) to $(BINDIR)/$(INSTALL_NAME)"
	@echo "  uninstall  - Uninstall $(INSTALL_NAME) from $(BINDIR)"
	@echo ""
	@echo "The script $(SCRIPT_NAME) must be present in the current directory."

install: $(SCRIPT_NAME)
	@echo "Installing $(SCRIPT_NAME) as $(INSTALL_NAME) to $(BINDIR)..."
	@mkdir -p $(BINDIR)
	@cp $(SCRIPT_NAME) $(BINDIR)/$(INSTALL_NAME)
	@chmod +x $(BINDIR)/$(INSTALL_NAME)
	@echo "Installation complete."
	@echo "You can now run 'sudo $(INSTALL_NAME) <command>'."

uninstall:
	@echo "Uninstalling $(INSTALL_NAME) from $(BINDIR)..."
	@rm -f $(BINDIR)/$(INSTALL_NAME)
	@echo "Uninstallation complete."

# Clean doesn't do much for this simple setup, but included for convention
clean:
	@echo "Nothing to clean for this simple Makefile."
