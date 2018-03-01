/// View Controller for login-specific screens
class LoginViewController: NUXViewController, LoginFacadeDelegate {
    @IBOutlet var instructionLabel: UILabel?
    @objc var errorToPresent: Error?
    var restrictToWPCom = false

    lazy var loginFacade: LoginFacade = {
        let facade = LoginFacade()
        facade.delegate = self
        return facade
    }()

    var isJetpackLogin: Bool {
        return loginFields.meta.jetpackLogin
    }

    // MARK: Lifecycle Methods

    override func viewDidLoad() {
        super.viewDidLoad()
        displayError(message: "")
        setupNavBarIcon()
        styleInstructions()

        if let error = errorToPresent {
            displayRemoteError(error)
        }
    }


    // MARK: - Setup and Configuration

    /// Places the WordPress logo in the navbar
    ///
    @objc func setupNavBarIcon() {
        addWordPressLogoToNavController()
    }

    /// Configures instruction label font
    ///
    @objc func styleInstructions() {
        instructionLabel?.font = WPStyleGuide.mediumWeightFont(forStyle: .subheadline)
    }

    func configureViewLoading(_ loading: Bool) {
        configureSubmitButton(animating: loading)
        navigationItem.hidesBackButton = loading
    }

    /// Sets the text of the error label.
    func displayError(message: String) {
        guard message.count > 0 else {
            errorLabel?.isHidden = true
            return
        }
        errorLabel?.isHidden = false
        errorLabel?.text = message
    }

    fileprivate func shouldShowEpilogue() -> Bool {
        if !isJetpackLogin {
            return true
        }
        let context = ContextManager.sharedInstance().mainContext
        let accountService = AccountService(managedObjectContext: context)
        guard
            let objectID = loginFields.meta.jetpackBlogID,
            let blog = context.object(with: objectID) as? Blog,
            let account = blog.account
            else {
                return false
        }
        return accountService.isDefaultWordPressComAccount(account)
    }

    func dismiss() {
        if shouldShowEpilogue() {

            if let linkSource = loginFields.meta.emailMagicLinkSource,
                linkSource == .signup {
                    performSegue(withIdentifier: .showSignupEpilogue, sender: self)
            } else {
                performSegue(withIdentifier: .showEpilogue, sender: self)
            }

            return
        }

        dismissBlock?(false)
        navigationController?.dismiss(animated: true, completion: nil)
    }

    /// Validates what is entered in the various form fields and, if valid,
    /// proceeds with login.
    ///
    func validateFormAndLogin() {
        view.endEditing(true)
        displayError(message: "")

        // Is everything filled out?
        if !loginFields.validateFieldsPopulatedForSignin() {
            let errorMsg = NSLocalizedString("Please fill out all the fields", comment: "A short prompt asking the user to properly fill out all login fields.")
            displayError(message: errorMsg)

            return
        }

        configureViewLoading(true)

        loginFacade.signIn(with: loginFields)
    }

    /// Manages data transfer when seguing to a new VC
    ///
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        guard let source = segue.source as? LoginViewController else {
            return
        }

        if let destination = segue.destination as? LoginEpilogueViewController {
            destination.dismissBlock = source.dismissBlock
            destination.jetpackLogin = source.loginFields.meta.jetpackLogin
        } else if let destination = segue.destination as? LoginViewController {
            destination.loginFields = source.loginFields
            destination.restrictToWPCom = source.restrictToWPCom
            destination.dismissBlock = source.dismissBlock
            destination.errorToPresent = source.errorToPresent
        }
    }

    // MARK: SigninWPComSyncHandler methods
    dynamic func finishedLogin(withUsername username: String, authToken: String, requiredMultifactorCode: Bool) {
        syncWPCom(username: username, authToken: authToken, requiredMultifactor: requiredMultifactorCode)
        guard let service = loginFields.meta.socialService, service == SocialServiceName.google,
            let token = loginFields.meta.socialServiceIDToken else {
                return
        }

        let accountService = AccountService(managedObjectContext: ContextManager.sharedInstance().mainContext)
        accountService.connectToSocialService(service, serviceIDToken: token, success: {
            WordPressAuthenticator.post(event: .loginSocialConnectSuccess)
            WordPressAuthenticator.post(event: .loginSocialSuccess)
        }, failure: { error in
            DDLogError(error.description)
            WordPressAuthenticator.post(event: .loginSocialConnectFailure(error: error))
            // We're opting to let this call fail silently.
            // Our user has already successfully authenticated and can use the app --
            // connecting the social service isn't critical.  There's little to
            // be gained by displaying an error that can not currently be resolved
            // in the app and doing so might tarnish an otherwise satisfying login
            // experience.
            // If/when we add support for manually connecting/disconnecting services
            // we can revisit.
        })
    }

    func configureStatusLabel(_ message: String) {
        // this is now a no-op, unless status labels return
    }

    /// Overridden here to direct these errors to the login screen's error label
    dynamic func displayRemoteError(_ error: Error) {
        configureViewLoading(false)

        let err = error as NSError
        guard err.code != 403 else {
            let message = NSLocalizedString("Whoops, something went wrong and we couldn't log you in. Please try again!", comment: "An error message shown when a wpcom user provides the wrong password.")
            displayError(message: message)
            return
        }

        displayError(err, sourceTag: sourceTag)
    }

    func needsMultifactorCode() {
        displayError(message: "")
        configureViewLoading(false)

        WordPressAuthenticator.post(event: .twoFactorCodeRequested)
        self.performSegue(withIdentifier: .show2FA, sender: self)
    }
}


// MARK: - Sync Helpers
//
extension LoginViewController {

    ///
    ///
    func syncWPCom(username: String, authToken: String, requiredMultifactor: Bool) {
        SafariCredentialsService.updateSafariCredentialsIfNeeded(with: loginFields)

        configureStatusLabel(NSLocalizedString("Getting account information", comment: "Alerts the user that wpcom account information is being retrieved."))

        let service = SigninWordPressComService()
        service.syncWPCom(username: username, authToken: authToken, isJetpackLogin: isJetpackLogin, onSuccess: { [weak self] in
            self?.didSyncWordPressCom(requiredMultifactor: requiredMultifactor)
            self?.resetStatusAndDismiss()

        }, onFailure: { [weak self] error in
            self?.failedSyncWordPressCom(with: error)
            self?.resetStatusAndDismiss()
        })
    }

    ///
    ///
    private func didSyncWordPressCom(requiredMultifactor: Bool) {
        /// HACK: An alternative notification to LoginFinished. Observe this instead of `WPSigninDidFinishNotification` for Jetpack logins.
        /// When WPTabViewController no longer destroy's and rebuilds the view hierarchy this alternate notification can be removed.
        ///
        let notification = self.isJetpackLogin ? .wordpressLoginFinishedJetpackLogin : Foundation.Notification.Name(rawValue: WordPressAuthenticator.WPSigninDidFinishNotification)
//        NotificationCenter.default.post(name: notification, object: account)
// TODO: FIXME
        /// Tracker
        ///
        let properties = [
            "multifactor": requiredMultifactor.description,
            "dotcom_user": true.description
        ]

        WordPressAuthenticator.post(event: .signedIn(properties: properties))
    }

    ///
    ///
    private func failedSyncWordPressCom(with error: Error) {
        /// At this point the user is authed and there is a valid account in core data. Make a note of the error and just dismiss
        /// the vc. There might be some wonkiness due to missing data (blogs, account info) but this will eventually resync.
        ///
        DDLogError("Error while syncing wpcom account and/or blog details after authentiating. \(String(describing: error))")
    }

    ///
    ///
    private func resetStatusAndDismiss() {
        self.configureStatusLabel("")
        self.configureViewLoading(false)
        self.dismiss()
    }
}
