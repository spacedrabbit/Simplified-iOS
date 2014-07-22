#import "NSMutableURLRequest+NYPLBasicAuthenticationAdditions.h"
#import "NYPLConfiguration.h"
#import "NYPLKeychain.h"
#import "NYPLSettings.h"
#import "NYPLSettingsCredentialView.h"

#import "NYPLSettingsCredentialViewController.h"

@interface NYPLSettingsCredentialViewController () <NSURLSessionDelegate, UITextFieldDelegate>

@property (nonatomic, readonly) NYPLSettingsCredentialView *credentialView;
@property (nonatomic, copy) void (^completionHandler)();
@property (nonatomic) NSURLSession *session;
@property (nonatomic) UIView *shieldView;
@property (nonatomic) UIViewController *viewController;

@end

@implementation NYPLSettingsCredentialViewController

+ (instancetype)sharedController
{
  static dispatch_once_t predicate;
  static NYPLSettingsCredentialViewController *sharedController = nil;
  
  dispatch_once(&predicate, ^{
    sharedController = [[self alloc] initWithNibName:@"NYPLSettingsCredentialView"
                                              bundle:[NSBundle mainBundle]];
    if(!sharedController) {
      NYPLLOG(@"Failed to create shared settings credential controller.");
    }
  });
  
  return sharedController;
}

- (NYPLSettingsCredentialView *)credentialView
{
  return (NYPLSettingsCredentialView *)self.view;
}

#pragma mark UIViewController

- (instancetype)initWithNibName:(NSString *)nibNameOrNil
                         bundle:(NSBundle *)nibBundleOrNil
{
  self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil];
  if(!self) return nil;
  
  self.credentialView.navigationItem.leftBarButtonItem.action = @selector(didSelectCancel);
  self.credentialView.navigationItem.leftBarButtonItem.target = self;
  
  self.credentialView.navigationItem.rightBarButtonItem.action = @selector(didSelectContinue);
  self.credentialView.navigationItem.rightBarButtonItem.target = self;
  
  [self.credentialView.barcodeField
   addTarget:self
   action:@selector(fieldsDidChange)
   forControlEvents:UIControlEventEditingChanged];
  
  self.credentialView.barcodeField.delegate = self;
  
  [self.credentialView.PINField
   addTarget:self
   action:@selector(fieldsDidChange)
   forControlEvents:UIControlEventEditingChanged];
  
  self.credentialView.PINField.delegate = self;
  
  self.session = [NSURLSession
                  sessionWithConfiguration:[NSURLSessionConfiguration ephemeralSessionConfiguration]
                  delegate:self
                  delegateQueue:[NSOperationQueue mainQueue]];
  
  return self;
}

- (void)viewWillAppear:(__attribute__((unused)) BOOL)animated
{
  self.credentialView.barcodeField.text = @"";
  self.credentialView.PINField.text = @"";
  self.credentialView.navigationItem.rightBarButtonItem.enabled = NO;
}

- (void)viewDidAppear:(__attribute__((unused)) BOOL)animated
{
  [self.credentialView.barcodeField becomeFirstResponder];
}

#pragma mark UITextViewDelegate

- (BOOL)textFieldShouldReturn:(UITextField *const)textField
{
  if(textField == self.credentialView.barcodeField) {
    [self.credentialView.PINField becomeFirstResponder];
  } else {
    [self.credentialView.PINField resignFirstResponder];
  }
  
  return YES;
}

#pragma mark -

- (void)requestCredentialsFromViewController:(UIViewController *const)viewController
                           completionHandler:(void (^)())handler
{
  if(!(viewController && handler)) {
    @throw NSInvalidArgumentException;
  }
  
  if(self.completionHandler) {
    @throw NSInternalInconsistencyException;
  }
  
  self.completionHandler = handler;
  
  self.modalPresentationStyle = UIModalPresentationFormSheet;
  
  [viewController presentViewController:self animated:YES completion:^{}];
}

- (void)didSelectCancel
{
  [self dismissViewControllerAnimated:YES completion:^{}];
  
  self.completionHandler = nil;
}

- (void)fieldsDidChange
{
  self.credentialView.navigationItem.rightBarButtonItem.enabled =
  (self.credentialView.barcodeField.text.length > 0 &&
   self.credentialView.PINField.text.length > 0);
}

- (void)setShieldEnabled:(BOOL)enabled
{
  if(enabled && !self.shieldView) {
    [self.credentialView.barcodeField resignFirstResponder];
    [self.credentialView.PINField resignFirstResponder];
    self.shieldView = [[UIView alloc] initWithFrame:self.view.bounds];
    self.shieldView.autoresizingMask = (UIViewAutoresizingFlexibleWidth |
                                        UIViewAutoresizingFlexibleHeight);
    self.shieldView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    UIActivityIndicatorView *const activityIndicatorView =
      [[UIActivityIndicatorView alloc]
        initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleWhiteLarge];
    activityIndicatorView.autoresizingMask = (UIViewAutoresizingFlexibleLeftMargin |
                                              UIViewAutoresizingFlexibleRightMargin |
                                              UIViewAutoresizingFlexibleTopMargin |
                                              UIViewAutoresizingFlexibleBottomMargin);
    [self.shieldView addSubview:activityIndicatorView];
    activityIndicatorView.center = self.shieldView.center;
    [activityIndicatorView startAnimating];
    [self.view addSubview:self.shieldView];
  } else {
    [self.shieldView removeFromSuperview];
    self.shieldView = nil;
  }
}

- (void)didSelectContinue
{
  assert(self.credentialView.barcodeField.text.length > 0);
  assert(self.credentialView.PINField.text.length > 0);
  
  [self setShieldEnabled:YES];
  
  [self validateCredentials];
}

- (void)validateCredentials
{
  NSMutableURLRequest *const request = [NSMutableURLRequest requestWithURL:
                                        [NYPLConfiguration loanURL]];
  
  request.HTTPMethod = @"HEAD";
  request.timeoutInterval = 10.0;
  
  [request setBasicAuthenticationUsername:self.credentialView.barcodeField.text
                                 password:self.credentialView.PINField.text];
  
  NSURLSessionDataTask *const task =
    [self.session
     dataTaskWithRequest:request
     completionHandler:^(__attribute__((unused)) NSData *data,
                         NSURLResponse *const response,
                         NSError *const error) {
       
       [self setShieldEnabled:NO];
       
       // This cast is always valid accord to Apple's documentation for NSHTTPURLResponse.
       NSInteger statusCode = ((NSHTTPURLResponse *) response).statusCode;
       
       if(error || (statusCode != 400 && statusCode != 401)) {
         if(!error) {
           NYPLLOG(@"Ignoring unexpected HTTP status code.");
         }
         [[[UIAlertView alloc]
           initWithTitle:NSLocalizedString(@"NYPLSettingsCredentialViewLoginFailed", nil)
           message:NSLocalizedString(@"CheckConnection", nil)
           delegate:nil
           cancelButtonTitle:nil
           otherButtonTitles:NSLocalizedString(@"OK", nil), nil]
          show];
         return;
       }
       
       if(statusCode == 400) {
         [[NYPLKeychain sharedKeychain] setObject:self.credentialView.barcodeField.text
                                           forKey:NYPLSettingsBarcodeKey];
         
         [[NYPLKeychain sharedKeychain] setObject:self.credentialView.PINField.text
                                           forKey:NYPLSettingsBarcodeKey];
         [self dismissViewControllerAnimated:YES completion:^{}];
         void (^handler)() = self.completionHandler;
         self.completionHandler = nil;
         handler();
       } else if(statusCode == 401) {
         [[[UIAlertView alloc]
           initWithTitle:NSLocalizedString(@"NYPLSettingsCredentialViewLoginFailed", nil)
           message:NSLocalizedString(@"NYPLSettingsCredentialViewInvalidCredentials", nil)
           delegate:nil
           cancelButtonTitle:nil
           otherButtonTitles:NSLocalizedString(@"OK", nil), nil]
          show];
         self.credentialView.PINField.text = @"";
         [self fieldsDidChange];
         [self.credentialView.PINField becomeFirstResponder];
       } else {
         // Unreachable.
         abort();
       }
     }];
  
  [task resume];
}

@end
