<?php
namespace Drupal\demo_portal\EventSubscriber;

use Drupal\samlauth\Event\SamlauthEvents;
use Drupal\samlauth\Event\SamlauthUserSyncEvent;
use Symfony\Component\EventDispatcher\EventSubscriberInterface;

final class RoleSync implements EventSubscriberInterface {
  public static function getSubscribedEvents(): array {
    return [SamlauthEvents::USER_SYNC => 'synchronize'];
  }
  public function synchronize(SamlauthUserSyncEvent $event): void {
    $attributes = $event->getAttributes();
    $user = $event->getAccount();
    $affiliations = [];
    // Entra mode trusts only the app-role claim; the legacy path trusts only eduPersonAffiliation.
    $claims = getenv('DRUPAL_AUTH') === 'entra'
      ? ['appRoles', 'roles', 'http://schemas.microsoft.com/ws/2008/06/identity/claims/role']
      : ['eduPersonAffiliation'];
    foreach ($claims as $claim) $affiliations = array_merge($affiliations, (array)($attributes[$claim] ?? []));
    $editor = (bool)array_intersect(['staff', 'faculty'], $affiliations);
    if ($editor && !$user->hasRole('editor')) { $user->addRole('editor'); $event->markAccountChanged(); }
    if (!$editor && $user->hasRole('editor')) { $user->removeRole('editor'); $event->markAccountChanged(); }
    \Drupal::request()->getSession()->set('demo.saml_attributes', $attributes);
  }
}
