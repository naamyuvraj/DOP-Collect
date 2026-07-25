/// Central portal constants.
///
/// The Agent Login URL is the redirect target of https://dopagent.indiapost.gov.in
/// — note LOGIN_FLAG=3 and AGENT_FLAG=Y, which select the *Agent* login. Using
/// LOGIN_FLAG=1 lands on the retail Personal Banking form instead.
class Portal {
  static const agentLoginUrl =
      'https://dopagent.indiapost.gov.in/corp/AuthenticationController'
      '?FORMSGROUP_ID__=AuthenticationFG&__START_TRAN_FLAG__=Y'
      '&__FG_BUTTONS__=LOAD&ACTION.LOAD=Y&AuthenticationFG.LOGIN_FLAG=3'
      '&BANK_ID=DOP&AGENT_FLAG=Y';
}
