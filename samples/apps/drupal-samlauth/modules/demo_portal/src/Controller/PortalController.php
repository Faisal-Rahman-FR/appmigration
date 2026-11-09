<?php
namespace Drupal\demo_portal\Controller;

use Drupal\Core\Controller\ControllerBase;
use Drupal\Core\Link;
use Drupal\Core\Url;
use Drupal\Component\Utility\Html;

final class PortalController extends ControllerBase {
  public function home(): array {
    $title = getenv('DRUPAL_AUTH') === 'entra' ? 'Sign in with Microsoft Entra ID' : 'Sign in with Shibboleth';
    return ['useCase'=>['#plain_text'=>'UC-04 — Drupal Research Publishing'], 'login'=>Link::fromTextAndUrl($title, Url::fromRoute('samlauth.saml_controller_login'))->toRenderable(), '#cache'=>['max-age'=>0]];
  }
  public function profile(): array {
    $user = $this->currentUser();
    $attributes = (array)\Drupal::request()->getSession()->get('demo.saml_attributes', []);
    $markup = '<p data-testid="uid">'.Html::escape($user->getAccountName()).'</p><p data-testid="roles">'.Html::escape(implode(', ', $user->getRoles())).'</p><dl>';
    foreach ($attributes as $name=>$values) if ($name !== 'uid') $markup .= '<dt>'.Html::escape($name).'</dt><dd data-testid="'.Html::escape($name).'">'.Html::escape(implode('; ', (array)$values)).'</dd>';
    return [
      'identity'=>['#markup'=>$markup.'</dl>'],
      'editor'=>Link::fromTextAndUrl('Editor workspace', Url::fromRoute('demo_portal.editor'))->toRenderable(),
      'logout'=>Link::fromTextAndUrl('Sign out', Url::fromRoute('samlauth.saml_controller_logout'))->toRenderable(),
      '#cache'=>['max-age'=>0],
    ];
  }
  public function editor(): array {
    return ['content'=>['#markup'=>'<p>Restricted editorial workspace. Seeded articles are editable in Drupal.</p>'],
      'articles'=>Link::fromTextAndUrl('Manage articles', Url::fromRoute('system.admin_content'))->toRenderable(), '#cache'=>['max-age'=>0]];
  }
}
